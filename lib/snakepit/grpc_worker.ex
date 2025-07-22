defmodule Snakepit.GRPCWorker do
  @moduledoc """
    A GenServer that manages gRPC connections to external processes.

    This worker can handle both traditional request/response and streaming operations
    via gRPC instead of stdin/stdout communication.

    ## Features

    - Automatic gRPC connection management
  - Health check monitoring
  - Streaming support with callback-based API
  - Session affinity for stateful operations
  - Graceful fallback to traditional workers if gRPC unavailable

  ## Usage

      # Start a gRPC worker
      {:ok, worker} = Snakepit.GRPCWorker.start_link(adapter: Snakepit.Adapters.GRPCPython)

      # Simple execution
      {:ok, result} = Snakepit.GRPCWorker.execute(worker, "ping", %{})

      # Streaming execution
      Snakepit.GRPCWorker.execute_stream(worker, "batch_inference", %{
        batch_items: ["img1.jpg", "img2.jpg"]
      }, fn chunk ->
        IO.puts("Processed: \#{chunk["item"]}")
      end)
  """

  use GenServer
  require Logger

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @type worker_state :: %{
          adapter: module(),
          port: integer(),
          channel: term() | nil,
          health_check_ref: reference() | nil,
          stats: map(),
          session_id: String.t()
        }

  # Client API

  @doc """
  Start a gRPC worker with the given adapter.
  """
  def start_link(opts) do
    worker_id = Keyword.get(opts, :id)

    name =
      if worker_id do
        {:via, Registry, {Snakepit.Pool.Registry, worker_id, %{worker_module: __MODULE__}}}
      else
        nil
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Execute a command and return the result.
  """
  # Header for default values
  def execute(worker, command, args, timeout \\ 30_000)

  def execute(worker_id, command, args, timeout) when is_binary(worker_id) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:execute, command, args, timeout}, timeout + 1_000)

      [] ->
        {:error, :worker_not_found}
    end
  end

  def execute(worker_pid, command, args, timeout) when is_pid(worker_pid) do
    GenServer.call(worker_pid, {:execute, command, args, timeout}, timeout + 1_000)
  end

  @doc """
  Execute a streaming command with callback.
  """
  def execute_stream(worker, command, args, callback_fn, timeout \\ 300_000)

  def execute_stream(worker_id, command, args, callback_fn, timeout) when is_binary(worker_id) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] ->
        GenServer.call(
          pid,
          {:execute_stream, command, args, callback_fn, timeout},
          timeout + 1_000
        )

      [] ->
        {:error, :worker_not_found}
    end
  end

  def execute_stream(worker_pid, command, args, callback_fn, timeout) when is_pid(worker_pid) do
    GenServer.call(
      worker_pid,
      {:execute_stream, command, args, callback_fn, timeout},
      timeout + 1_000
    )
  end

  @doc """
  Execute a command in a specific session.
  """
  def execute_in_session(worker, session_id, command, args, timeout \\ 30_000) do
    GenServer.call(
      worker,
      {:execute_session, session_id, command, args, timeout},
      timeout + 1_000
    )
  end

  @doc """
  Get worker health and statistics.
  """
  def get_health(worker) do
    GenServer.call(worker, :get_health)
  end

  @doc """
  Get worker information and capabilities.
  """
  def get_info(worker) do
    GenServer.call(worker, :get_info)
  end
  
  @doc """
  Get the gRPC channel for direct client usage.
  """
  def get_channel(worker) do
    GenServer.call(worker, :get_channel)
  end
  
  @doc """
  Get the session ID for this worker.
  """
  def get_session_id(worker) do
    GenServer.call(worker, :get_session_id)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    worker_id = Keyword.fetch!(opts, :id)
    port = adapter.get_port()
    
    # Generate unique session ID
    session_id = "session_#{:erlang.unique_integer([:positive, :monotonic])}_#{:erlang.system_time(:microsecond)}"

    # Start the gRPC server process non-blocking
    executable = adapter.executable_path()
    script = adapter.script_path()
    adapter_args = adapter.script_args() || []

    args =
      if Enum.any?(adapter_args, &String.contains?(&1, "--port")) do
        adapter_args
      else
        adapter_args ++ ["--port", to_string(port)]
      end

    Logger.info("Starting gRPC server: #{executable} #{script} #{Enum.join(args, " ")}")

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, [script | args]},
      {:cd, Path.dirname(script)}
    ]

    server_port = Port.open({:spawn_executable, executable}, port_opts)
    Port.monitor(server_port)

    # Extract external process PID for cleanup registry
    process_pid =
      case Port.info(server_port, :os_pid) do
        {:os_pid, pid} ->
          Logger.info("Started gRPC server process, will listen on TCP port #{port}")
          pid

        error ->
          Logger.error("Failed to get gRPC server process PID: #{inspect(error)}")
          nil
      end

    state = %{
      id: worker_id,
      adapter: adapter,
      port: port,
      server_port: server_port,
      process_pid: process_pid,
      session_id: session_id,
      # Will be established in handle_continue
      connection: nil,
      health_check_ref: nil,
      stats: %{
        requests: 0,
        errors: 0,
        start_time: System.monotonic_time(:millisecond)
      }
    }

    # Return immediately and schedule the blocking work for later
    {:ok, state, {:continue, :connect_and_wait}}
  end

  @impl true
  def handle_continue(:connect_and_wait, state) do
    # Now we do the blocking work here, after init/1 has returned
    case wait_for_server_ready(state.server_port, 5000) do
      {:ok, actual_port} ->
        case state.adapter.init_grpc_connection(actual_port) do
          {:ok, connection} ->
            # *** CRITICAL: Register with ProcessRegistry for ApplicationCleanup safety net ***
            Snakepit.Pool.ProcessRegistry.register_worker(
              state.id,
              self(),
              state.process_pid,
              "grpc_worker"
            )

            Logger.info(
              "gRPC worker #{state.id} registered process PID #{state.process_pid} with ProcessRegistry."
            )

            # Schedule health checks
            health_ref = schedule_health_check()

            Logger.info("✅ gRPC worker #{state.id} initialization complete.")
            {:noreply, %{state | connection: connection, health_check_ref: health_ref}}

          {:error, reason} ->
            Logger.error("Failed to connect to gRPC server: #{reason}")
            {:stop, {:grpc_connection_failed, reason}, state}
        end

      {:error, reason} ->
        Logger.error("Failed to start gRPC server: #{reason}")
        {:stop, {:grpc_server_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:execute, command, args, timeout}, _from, state) do
    case state.adapter.grpc_execute(state.connection, command, args, timeout) do
      {:ok, result} ->
        new_state = update_stats(state, :success)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        new_state = update_stats(state, :error)
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:execute_stream, command, args, callback_fn, timeout}, _from, state) do
    Logger.info(
      "[GRPCWorker] handle_call execute_stream - command: #{command}, args: #{inspect(args)}"
    )

    result =
      state.adapter.grpc_execute_stream(
        state.connection,
        command,
        args,
        callback_fn,
        timeout
      )

    Logger.info("[GRPCWorker] grpc_execute_stream returned: #{inspect(result)}")

    new_state =
      case result do
        :ok -> update_stats(state, :success)
        {:error, _reason} -> update_stats(state, :error)
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:execute_session, session_id, command, args, timeout}, _from, state) do
    session_args = Map.put(args, :session_id, session_id)

    case state.adapter.grpc_execute(state.connection, command, session_args, timeout) do
      {:ok, result} ->
        new_state = update_stats(state, :success)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        new_state = update_stats(state, :error)
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    # Make gRPC health check call
    health_result = make_health_check(state)
    {:reply, health_result, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    # Make gRPC info call
    info_result = make_info_call(state)
    {:reply, info_result, state}
  end

  @impl true
  def handle_call(:get_channel, _from, state) do
    if state.connection do
      {:reply, {:ok, state.connection.channel}, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:get_session_id, _from, state) do
    {:reply, {:ok, state.session_id}, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    case make_health_check(state) do
      {:ok, _health} ->
        # Health check passed, schedule next one
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}

      {:error, reason} ->
        Logger.warning("Health check failed: #{reason}")
        # Could implement reconnection logic here
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :port, port, reason}, %{server_port: port} = state) do
    Logger.error("External gRPC process died: #{inspect(reason)}")
    {:stop, {:external_process_died, reason}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{server_port: port} = state) do
    Logger.info("gRPC server output: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{server_port: port} = state) do
    Logger.error("gRPC server exited with status: #{status}")
    {:stop, {:grpc_server_exited, status}, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Define graceful shutdown timeout - configurable
  # 2 seconds
  @graceful_shutdown_timeout 2000

  @impl true
  def terminate(reason, state) do
    Logger.info("gRPC worker #{inspect(self())} terminating with reason: #{inspect(reason)}")

    # Graceful shutdown logic should only apply to a normal :shutdown
    # For crashes, we want to exit immediately and let the supervisor handle it.
    if reason == :shutdown and state.process_pid do
      Logger.debug(
        "Starting graceful shutdown of external gRPC process PID: #{state.process_pid}..."
      )

      # Monitor the port to get a :DOWN message when the OS process *actually* dies
      ref = Port.monitor(state.server_port)

      # 1. Send SIGTERM FIRST. This is the signal for the Python script
      #    to begin its graceful shutdown via its signal_handler.
      System.cmd("kill", ["-TERM", to_string(state.process_pid)])

      # 2. WAIT for the process to exit. The Python server's grace period is 1s,
      #    so we wait for 2s. If the port dies, we get a :DOWN message.
      receive do
        {:DOWN, ^ref, :port, _port, _exit_reason} ->
          Logger.debug("✅ gRPC server PID #{state.process_pid} confirmed graceful exit.")
      after
        @graceful_shutdown_timeout ->
          # 3. ESCALATE to SIGKILL if it doesn't shut down in time.
          Logger.warning(
            "⏰ gRPC server PID #{state.process_pid} did not exit gracefully within #{@graceful_shutdown_timeout}ms. Forcing SIGKILL."
          )

          System.cmd("kill", ["-KILL", to_string(state.process_pid)], stderr_to_stdout: true)
      end

      # Clean up the monitor message if it's still in the mailbox
      Process.demonitor(ref, [:flush])
    end

    # 4. Final resource cleanup (run regardless of shutdown reason)
    if state.connection do
      GRPC.Stub.disconnect(state.connection.channel)
    end

    if state.health_check_ref do
      Process.cancel_timer(state.health_check_ref)
    end

    # The Port will be closed automatically when the GenServer terminates.
    # Calling Port.close() is still good practice if you need to be explicit.
    if state.server_port, do: Port.close(state.server_port)

    # *** CRITICAL: Unregister from ProcessRegistry as the very last step ***
    Snakepit.Pool.ProcessRegistry.unregister_worker(state.id)

    :ok
  end

  # Private functions

  ##
  # defp wait_for_server_ready(port, expected_port, timeout) do
  #   receive do
  #     {^port, {:data, data}} ->
  #       output = to_string(data)

  #       cond do
  #         String.contains?(output, "gRPC Bridge started") ->
  #           Logger.info("gRPC worker started successfully on port #{expected_port}")
  #           Logger.info("gRPC server output: #{String.trim(output)}")
  #           {:ok, port}

  #         true ->
  #           # Keep waiting for the ready message
  #           wait_for_server_ready(port, expected_port, timeout)
  #       end

  #     {:DOWN, _ref, :port, ^port, reason} ->
  #       {:error, "gRPC server crashed during startup: #{inspect(reason)}"}
  #   after
  #     timeout ->
  #       Port.close(port)
  #       {:error, "gRPC server failed to start within #{timeout}ms"}
  #   end
  # end

  defp wait_for_server_ready(port, timeout) do
    receive do
      {^port, {:data, data}} ->
        output = to_string(data)

        # Look for the ready message anywhere in the output
        if String.contains?(output, "GRPC_READY:") do
          # Extract port from the ready message line
          lines = String.split(output, "\n")
          ready_line = Enum.find(lines, &String.contains?(&1, "GRPC_READY:"))

          if ready_line do
            case Regex.run(~r/GRPC_READY:(\d+)/, ready_line) do
              [_, port_str] ->
                {:ok, String.to_integer(port_str)}
              _ ->
                wait_for_server_ready(port, timeout)
            end
          else
            wait_for_server_ready(port, timeout)
          end
        else
          # Keep waiting for the ready message
          wait_for_server_ready(port, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp schedule_health_check do
    # Health check every 30 seconds
    Process.send_after(self(), :health_check, 30_000)
  end

  defp make_health_check(state) do
    case Snakepit.GRPC.Client.health(state.connection.channel, inspect(self())) do
      {:ok, health_response} ->
        {:ok, health_response}

      {:error, _reason} ->
        {:error, :health_check_failed}
    end
  end

  defp make_info_call(state) do
    case Snakepit.GRPC.Client.get_info(state.connection.channel) do
      {:ok, info_response} ->
        {:ok, info_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_stats(state, result) do
    stats =
      case result do
        :success ->
          %{state.stats | requests: state.stats.requests + 1}

        :error ->
          %{
            state.stats
            | requests: state.stats.requests + 1,
              errors: state.stats.errors + 1
          }
      end

    %{state | stats: stats}
  end
end
