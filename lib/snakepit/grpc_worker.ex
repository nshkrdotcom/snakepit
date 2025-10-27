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
  alias Snakepit.Telemetry.Correlation
  alias Snakepit.Logger.Redaction
  alias Snakepit.Logger, as: SLog
  require OpenTelemetry.Tracer, as: Tracer

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
          connection: map() | nil,
          port: integer(),
          process_pid: integer() | nil,
          server_port: port() | nil,
          id: String.t(),
          pool_name: atom() | pid(),
          health_check_ref: reference() | nil,
          heartbeat_monitor: pid() | nil,
          heartbeat_config: map(),
          stats: map(),
          session_id: String.t(),
          worker_config: map()
        }

  @base_heartbeat_defaults %{
    enabled: true,
    ping_interval_ms: 2_000,
    timeout_ms: 10_000,
    max_missed_heartbeats: 3,
    ping_fun: nil,
    test_pid: nil,
    initial_delay_ms: 0,
    dependent: true
  }

  @heartbeat_known_keys Map.keys(@base_heartbeat_defaults)
  @heartbeat_known_key_strings Enum.map(@heartbeat_known_keys, &Atom.to_string/1)

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
    # CRITICAL: Trap exits so terminate/2 is called on shutdown
    # Without this, the GenServer is brutally killed and Python processes are orphaned!
    Process.flag(:trap_exit, true)

    adapter = Keyword.fetch!(opts, :adapter)
    worker_id = Keyword.fetch!(opts, :id)
    # CRITICAL FIX: Get pool_name from opts so worker knows which pool to notify
    # This can be an atom (registered name) or a PID
    pool_name = Keyword.get(opts, :pool_name, Snakepit.Pool)
    port = adapter.get_port()

    # CRITICAL: Reserve the worker slot BEFORE spawning the process
    # This ensures we can track the process even if we crash during spawn
    case Snakepit.Pool.ProcessRegistry.reserve_worker(worker_id) do
      :ok ->
        SLog.debug("Reserved worker slot for #{worker_id}")
        # Generate unique session ID
        session_id =
          "session_#{:erlang.unique_integer([:positive, :monotonic])}_#{:erlang.system_time(:microsecond)}"

        # Get the address of the central Elixir gRPC server
        elixir_grpc_host = Application.get_env(:snakepit, :grpc_host, "localhost")
        elixir_grpc_port = Application.get_env(:snakepit, :grpc_port, 50051)
        elixir_address = "#{elixir_grpc_host}:#{elixir_grpc_port}"

        # CRITICAL: Get worker_config FIRST to use per-worker adapter settings
        worker_config = Keyword.get(opts, :worker_config, %{})

        heartbeat_config =
          worker_config
          |> get_worker_config_section(:heartbeat)
          |> normalize_heartbeat_config()

        # Start the gRPC server process non-blocking
        executable = adapter.executable_path()

        # Use worker-specific adapter_args if provided, else fall back to adapter defaults
        # CRITICAL: Empty list [] is truthy, so check explicitly
        worker_adapter_args = Map.get(worker_config, :adapter_args, [])

        adapter_args =
          if worker_adapter_args == [] do
            adapter.script_args() || []
          else
            worker_adapter_args
          end

        adapter_env = Map.get(worker_config, :adapter_env, [])
        heartbeat_env_json = encode_heartbeat_env(heartbeat_config)

        # Determine which script to use based on adapter_args (threaded vs process mode)
        # If --max-workers is specified, use the threaded server
        script_path =
          if Enum.any?(adapter_args, fn arg ->
               is_binary(arg) and String.contains?(arg, "--max-workers")
             end) do
            # Threaded mode
            app_dir = Application.app_dir(:snakepit)
            Path.join([app_dir, "priv", "python", "grpc_server_threaded.py"])
          else
            # Process mode (default)
            adapter.script_path()
          end

        # Build args ensuring both port and elixir-address are included
        args = adapter_args

        # Add port if not already present
        args =
          if not Enum.any?(args, &String.contains?(&1, "--port")) do
            args ++ ["--port", to_string(port)]
          else
            args
          end

        # Add elixir-address if not already present
        args =
          if not Enum.any?(args, &String.contains?(&1, "--elixir-address")) do
            args ++ ["--elixir-address", elixir_address]
          else
            args
          end

        # Add short run-id for safer process cleanup
        # This short 7-char ID will be visible in ps output and used for cleanup
        # Use --snakepit-run-id to maintain compatibility with Python script
        run_id = Snakepit.Pool.ProcessRegistry.get_beam_run_id()
        args = args ++ ["--snakepit-run-id", run_id]

        SLog.info(
          "Starting gRPC server: #{executable} #{script_path || ""} #{Enum.join(args, " ")}"
        )

        # Spawn the Python executable directly. Cleanup is handled by ProcessKiller via run_id.
        # CRITICAL: Do NOT use setsid wrapper - it exits immediately with status 0 while the
        # actual Python process becomes an orphaned grandchild, causing the Port to think
        # the process died when it's actually still running.
        {spawn_args, port_opts} =
          case script_path do
            path when is_binary(path) and byte_size(path) > 0 ->
              {
                [path | args],
                [
                  :binary,
                  :exit_status,
                  :use_stdio,
                  :stderr_to_stdout,
                  {:cd, Path.dirname(path)}
                ]
              }

            _ ->
              {
                args,
                [
                  :binary,
                  :exit_status,
                  :use_stdio,
                  :stderr_to_stdout
                ]
              }
          end

        # Apply adapter_env to the spawned process if provided
        env_entries =
          adapter_env
          |> normalize_adapter_env_entries()
          |> maybe_put_heartbeat_env(heartbeat_env_json)

        port_opts =
          if env_entries != [] do
            env_tuples = Enum.map(env_entries, &to_env_tuple/1)
            port_opts ++ [{:env, env_tuples}]
          else
            port_opts
          end

        server_port =
          Port.open({:spawn_executable, executable}, [{:args, spawn_args} | port_opts])

        Port.monitor(server_port)

        # Extract external process PID for cleanup registry
        process_pid =
          case Port.info(server_port, :os_pid) do
            {:os_pid, pid} ->
              SLog.info("Started gRPC server process, will listen on TCP port #{port}")
              pid

            error ->
              SLog.error("Failed to get gRPC server process PID: #{inspect(error)}")
              nil
          end

        # CRITICAL FIX: Register the Python PID immediately after spawning
        # This prevents ApplicationCleanup from seeing it as an "orphan" during rapid shutdown
        # Before this fix, the PID was only registered after wait_for_server_ready succeeded,
        # causing a race condition where ApplicationCleanup would find "orphaned" processes
        if process_pid do
          case Snakepit.Pool.ProcessRegistry.activate_worker(
                 worker_id,
                 self(),
                 process_pid,
                 "grpc_worker"
               ) do
            :ok ->
              SLog.debug(
                "Registered Python PID #{process_pid} for worker #{worker_id} in ProcessRegistry"
              )

            {:error, reason} ->
              SLog.error(
                "Failed to register Python PID #{process_pid} for worker #{worker_id}: #{inspect(reason)}"
              )
          end
        end

        state = %{
          id: worker_id,
          pool_name: pool_name,
          adapter: adapter,
          port: port,
          server_port: server_port,
          process_pid: process_pid,
          session_id: session_id,
          requested_port: port,
          worker_config: worker_config,
          heartbeat_config: heartbeat_config,
          heartbeat_monitor: nil,
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

      {:error, reason} ->
        SLog.error("Failed to reserve worker slot for #{worker_id}: #{inspect(reason)}")
        {:stop, {:reservation_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:connect_and_wait, state) do
    # Now we do the blocking work here, after init/1 has returned
    case wait_for_server_ready(state.server_port, 30000) do
      {:ok, actual_port} ->
        case state.adapter.init_grpc_connection(actual_port) do
          {:ok, connection} ->
            # Python PID already registered in init/1, so just notify the pool
            # and register with lifecycle manager

            # CRITICAL: Check if Pool is alive first (test shutdown race condition)
            pool_pid =
              if is_atom(state.pool_name),
                do: Process.whereis(state.pool_name),
                else: state.pool_name

            pool_alive = pool_pid != nil and Process.alive?(pool_pid)

            if not pool_alive do
              # Pool already dead - gracefully stop without crashing
              SLog.debug(
                "Worker #{state.id} finished starting but Pool is shut down. Stopping gracefully."
              )

              {:stop, :normal, state}
            else
              case notify_pool_ready(pool_pid, state.id) do
                :ok ->
                  # Schedule health checks
                  health_ref = schedule_health_check()

                  # Register with lifecycle manager for automatic recycling
                  Snakepit.Worker.LifecycleManager.track_worker(
                    state.pool_name,
                    state.id,
                    self(),
                    state.worker_config
                  )

                  SLog.info("✅ gRPC worker #{state.id} initialization complete and acknowledged.")

                  maybe_initialize_session(connection, state.session_id)

                  new_state =
                    state
                    |> Map.put(:connection, connection)
                    |> Map.put(:port, actual_port)
                    |> Map.put(:health_check_ref, health_ref)
                    |> maybe_start_heartbeat_monitor()

                  {:noreply, new_state}

                {:error, reason} ->
                  SLog.debug(
                    "Pool handshake failed for worker #{state.id} (pool pid: #{inspect(pool_pid)}): #{inspect(reason)}"
                  )

                  {:stop, :shutdown, state}
              end
            end

          {:error, reason} ->
            SLog.error("Failed to connect to gRPC server: #{reason}")
            {:stop, {:grpc_connection_failed, reason}, state}
        end

      {:error, reason} ->
        # Suppress error logs for expected shutdown signals (143=SIGTERM, 137=SIGKILL, 0=graceful)
        case reason do
          {:exit_status, status} when status in [0, 137, 143] ->
            SLog.debug("gRPC server exited during startup with status #{status} (shutdown)")

          _ ->
            SLog.error("Failed to start gRPC server: #{inspect(reason)}")
        end

        {:stop, {:grpc_server_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:execute, command, args, timeout}, _from, state) do
    args_with_corr = ensure_correlation(args)

    case instrument_execute(
           :execute,
           state,
           command,
           args_with_corr,
           timeout,
           fn instrumented_args ->
             state.adapter.grpc_execute(
               state.connection,
               state.session_id,
               command,
               instrumented_args,
               timeout
             )
           end
         ) do
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
    SLog.debug("[GRPCWorker] execute_stream #{command} with args #{Redaction.describe(args)}")

    result =
      state.adapter.grpc_execute_stream(
        state.connection,
        state.session_id,
        command,
        args,
        callback_fn,
        timeout
      )

    SLog.debug("[GRPCWorker] execute_stream result: #{Redaction.describe(result)}")

    new_state =
      case result do
        :ok -> update_stats(state, :success)
        {:error, _reason} -> update_stats(state, :error)
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, {:ok, state.port}, state}
  end

  @impl true
  def handle_call(:get_port_metadata, _from, state) do
    info = %{
      current_port: state.port,
      requested_port: Map.get(state, :requested_port, state.port)
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call({:execute_session, session_id, command, args, timeout}, _from, state) do
    session_args =
      args
      |> Map.put(:session_id, session_id)
      |> ensure_correlation()

    case instrument_execute(
           :execute_session,
           state,
           command,
           session_args,
           timeout,
           fn instrumented_args ->
             state.adapter.grpc_execute(
               state.connection,
               state.session_id,
               command,
               instrumented_args,
               timeout
             )
           end
         ) do
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
        SLog.warning("Health check failed: #{reason}")
        # Could implement reconnection logic here
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :port, port, reason}, %{server_port: port} = state) do
    SLog.error("External gRPC process died: #{inspect(reason)}")
    {:stop, {:external_process_died, reason}, state}
  end

  @impl true
  def handle_info({:EXIT, monitor_pid, exit_reason}, %{heartbeat_monitor: monitor_pid} = state) do
    SLog.warning(
      "Heartbeat monitor for #{state.id} exited with #{inspect(exit_reason)}; terminating worker"
    )

    {:stop, {:shutdown, exit_reason}, %{state | heartbeat_monitor: nil}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{server_port: port} = state) do
    # Log server output for debugging
    output = String.trim(to_string(data))

    if output != "" do
      SLog.info("gRPC server output: #{output}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{server_port: port} = state) do
    # DIAGNOSTIC: Drain any remaining error output from the port buffer
    remaining_output = drain_port_buffer(port, 200)

    SLog.error("""
    🔴 Python gRPC server exited with status #{status}
    Worker: #{state.id}
    Port: #{state.port}
    PID: #{state.process_pid}
    Last output: #{remaining_output}
    """)

    {:stop, {:grpc_server_exited, status}, state}
  end

  @impl true
  def handle_info(msg, state) do
    SLog.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Define graceful shutdown timeout - configurable
  # 2000ms to accommodate Python server's async shutdown
  @graceful_shutdown_timeout 2000

  @impl true
  def terminate(reason, state) do
    SLog.debug(
      "GRPCWorker.terminate/2 called for #{state.id}, reason: #{inspect(reason)}, PID: #{state.process_pid}"
    )

    SLog.debug("gRPC worker #{state.id} terminating: #{inspect(reason)}")

    maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
    maybe_notify_test_pid(state.heartbeat_config, {:heartbeat_monitor_stopped, state.id, reason})

    # ALWAYS kill the Python process, regardless of reason
    # This is critical to prevent orphaned processes
    if state.process_pid do
      # Treat :shutdown and :normal as graceful shutdowns
      # :normal occurs when pool dies during worker startup - we should still be graceful
      if reason in [:shutdown, :normal] do
        # Graceful shutdown - use SIGTERM with escalation
        SLog.debug(
          "Starting graceful shutdown of external gRPC process PID: #{state.process_pid}..."
        )

        case Snakepit.ProcessKiller.kill_with_escalation(
               state.process_pid,
               @graceful_shutdown_timeout
             ) do
          :ok ->
            SLog.debug("✅ gRPC server PID #{state.process_pid} terminated gracefully")

          {:error, reason} ->
            SLog.warning("Failed to gracefully kill #{state.process_pid}: #{inspect(reason)}")
        end
      else
        # Non-graceful termination (crash, error, etc.) - immediate SIGKILL
        SLog.warning(
          "Non-graceful termination (#{inspect(reason)}), immediately killing PID #{state.process_pid}"
        )

        case Snakepit.ProcessKiller.kill_process(state.process_pid, :sigkill) do
          :ok ->
            SLog.debug("✅ Immediately killed gRPC server PID #{state.process_pid}")

          {:error, reason} ->
            SLog.warning("Failed to kill #{state.process_pid}: #{inspect(reason)}")
        end
      end
    end

    # Final resource cleanup (run regardless of shutdown reason)
    disconnect_connection(state.connection)

    if state.health_check_ref do
      Process.cancel_timer(state.health_check_ref)
    end

    # CRITICAL FIX: Defensively close port with comprehensive error handling
    # This ensures cleanup runs even during brutal kills (:kill reason)
    if state.server_port do
      safe_close_port(state.server_port)
    end

    # *** CRITICAL: Unregister from ProcessRegistry as the very last step ***
    Snakepit.Pool.ProcessRegistry.unregister_worker(state.id)

    :ok
  end

  defp notify_pool_ready(nil, _worker_id), do: {:error, :pool_not_found}

  defp notify_pool_ready(pool_pid, worker_id) when is_pid(pool_pid) do
    try do
      GenServer.call(pool_pid, {:worker_ready, worker_id}, 30_000)
    catch
      :exit, {:noproc, _} ->
        {:error, :pool_not_found}

      :exit, {:shutdown, _} = reason ->
        {:error, reason}

      :exit, {:killed, _} = reason ->
        {:error, reason}

      :exit, {:timeout, _} = reason ->
        {:error, reason}

      :exit, reason ->
        {:error, reason}
    else
      :ok ->
        :ok

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end

  defp maybe_start_heartbeat_monitor(state) do
    config = normalize_heartbeat_config(state.heartbeat_config)

    cond do
      not config[:enabled] ->
        maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
        %{state | heartbeat_config: config, heartbeat_monitor: nil}

      heartbeat_monitor_running?(state.heartbeat_monitor) ->
        %{state | heartbeat_config: config}

      state.connection == nil ->
        %{state | heartbeat_config: config}

      true ->
        monitor_opts = [
          {:worker_pid, self()},
          {:worker_id, state.id},
          {:ping_interval_ms, config[:ping_interval_ms]},
          {:timeout_ms, config[:timeout_ms]},
          {:max_missed_heartbeats, config[:max_missed_heartbeats]},
          {:initial_delay_ms, config[:initial_delay_ms]},
          {:dependent, config[:dependent]},
          {:ping_fun, config[:ping_fun] || build_default_ping_fun(state, config)}
        ]

        case Snakepit.HeartbeatMonitor.start_link(monitor_opts) do
          {:ok, monitor_pid} ->
            maybe_notify_test_pid(config, {:heartbeat_monitor_started, state.id, monitor_pid})

            %{state | heartbeat_monitor: monitor_pid, heartbeat_config: config}

          {:error, {:already_started, monitor_pid}} when is_pid(monitor_pid) ->
            maybe_notify_test_pid(config, {:heartbeat_monitor_started, state.id, monitor_pid})

            %{state | heartbeat_monitor: monitor_pid, heartbeat_config: config}

          {:error, reason} ->
            SLog.error("Failed to start heartbeat monitor for #{state.id}: #{inspect(reason)}")
            maybe_notify_test_pid(config, {:heartbeat_monitor_failed, state.id, reason})

            %{state | heartbeat_monitor: nil, heartbeat_config: config}
        end
    end
  end

  defp heartbeat_monitor_running?(pid) when is_pid(pid) do
    Process.alive?(pid)
  end

  defp heartbeat_monitor_running?(_), do: false

  defp build_default_ping_fun(state, config) do
    connection = state.connection
    adapter = state.adapter
    session_id = state.session_id
    channel = connection && Map.get(connection, :channel)

    fn timestamp ->
      result =
        cond do
          function_exported?(adapter, :grpc_heartbeat, 3) ->
            apply(adapter, :grpc_heartbeat, [connection, session_id, config])

          function_exported?(adapter, :grpc_heartbeat, 2) ->
            apply(adapter, :grpc_heartbeat, [connection, session_id])

          heartbeat_channel_available?(channel) ->
            Snakepit.GRPC.Client.heartbeat(channel, session_id, timeout: config[:timeout_ms])

          true ->
            {:error, :no_heartbeat_transport}
        end

      handle_heartbeat_response(self(), timestamp, result)
    end
  end

  defp heartbeat_channel_available?(channel) when is_map(channel), do: true
  defp heartbeat_channel_available?(channel) when is_struct(channel), do: true
  defp heartbeat_channel_available?(channel) when is_reference(channel), do: true
  defp heartbeat_channel_available?(channel) when is_pid(channel), do: true
  defp heartbeat_channel_available?(channel) when is_binary(channel), do: byte_size(channel) > 0
  defp heartbeat_channel_available?(_), do: false

  defp maybe_initialize_session(connection, session_id) do
    channel = connection && Map.get(connection, :channel)

    if heartbeat_channel_available?(channel) do
      try do
        _ = Snakepit.GRPC.Client.initialize_session(channel, session_id, %{})
        :ok
      rescue
        exception ->
          SLog.debug("Heartbeat session initialization failed: #{inspect(exception)}")
          :error
      catch
        :exit, reason ->
          SLog.debug("Heartbeat session initialization exited: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end

  defp handle_heartbeat_response(monitor_pid, timestamp, :ok) do
    Snakepit.HeartbeatMonitor.notify_pong(monitor_pid, timestamp)
    :ok
  end

  defp handle_heartbeat_response(monitor_pid, timestamp, {:ok, %{success: success}})
       when success in [true, true, 1] do
    Snakepit.HeartbeatMonitor.notify_pong(monitor_pid, timestamp)
    :ok
  end

  defp handle_heartbeat_response(_monitor_pid, _timestamp, {:ok, %{success: false} = payload}) do
    {:error, {:heartbeat_failed, payload}}
  end

  defp handle_heartbeat_response(monitor_pid, timestamp, {:ok, _response}) do
    Snakepit.HeartbeatMonitor.notify_pong(monitor_pid, timestamp)
    :ok
  end

  defp handle_heartbeat_response(_monitor_pid, _timestamp, {:error, reason}) do
    {:error, reason}
  end

  defp handle_heartbeat_response(_monitor_pid, _timestamp, other) do
    {:error, other}
  end

  defp maybe_notify_test_pid(%{test_pid: pid}, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp maybe_notify_test_pid(%{"test_pid" => pid}, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp maybe_notify_test_pid(_config, _message), do: :ok

  defp maybe_stop_heartbeat_monitor(nil), do: :ok

  defp maybe_stop_heartbeat_monitor(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp normalize_heartbeat_config(config) when is_map(config) do
    defaults = default_heartbeat_config()

    normalized =
      Enum.reduce(@heartbeat_known_keys, %{}, fn key, acc ->
        Map.put(acc, key, get_config_value(config, key, Map.get(defaults, key)))
      end)

    extras =
      config
      |> Enum.reject(fn {key, _value} -> heartbeat_known_key?(key) end)
      |> Map.new()

    Map.merge(extras, normalized)
  end

  defp normalize_heartbeat_config(_config), do: default_heartbeat_config()

  defp default_heartbeat_config do
    Map.merge(
      @base_heartbeat_defaults,
      Snakepit.Config.heartbeat_defaults(),
      fn _key, _base, override -> override end
    )
  end

  defp get_config_value(config, key, default) when is_atom(key) do
    cond do
      Map.has_key?(config, key) ->
        Map.get(config, key)

      Map.has_key?(config, Atom.to_string(key)) ->
        Map.get(config, Atom.to_string(key))

      true ->
        default
    end
  end

  defp heartbeat_known_key?(key) when is_atom(key) do
    key in @heartbeat_known_keys
  end

  defp heartbeat_known_key?(key) when is_binary(key) do
    key in @heartbeat_known_key_strings
  end

  defp disconnect_connection(nil), do: :ok

  defp disconnect_connection(%{channel: %GRPC.Channel{} = channel}) do
    try do
      GRPC.Stub.disconnect(channel)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp disconnect_connection(%{channel: channel}) when not is_nil(channel), do: :ok
  defp disconnect_connection(_), do: :ok

  defp get_worker_config_section(config, key) when is_map(config) and is_atom(key) do
    cond do
      Map.has_key?(config, key) ->
        Map.get(config, key)

      Map.has_key?(config, Atom.to_string(key)) ->
        Map.get(config, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp get_worker_config_section(_config, _key), do: nil

  defp encode_heartbeat_env(config) when is_map(config) do
    config
    |> Map.new()
    |> Map.take([
      :enabled,
      :ping_interval_ms,
      :timeout_ms,
      :max_missed_heartbeats,
      :initial_delay_ms,
      :dependent
    ])
    |> Enum.reduce(%{}, fn
      {:ping_interval_ms, value}, acc -> Map.put(acc, "interval_ms", value)
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      %{} = map when map == %{} -> nil
      map -> Jason.encode!(map)
    end
  end

  defp normalize_adapter_env_entries(nil), do: []

  defp normalize_adapter_env_entries(env) when is_map(env) do
    env
    |> Map.to_list()
    |> normalize_adapter_env_entries()
  end

  defp normalize_adapter_env_entries(env) when is_list(env) do
    Enum.flat_map(env, fn
      {key, value} -> [{to_string(key), to_string(value)}]
      key when is_binary(key) -> [{key, ""}]
      key when is_atom(key) -> [{Atom.to_string(key), ""}]
      _ -> []
    end)
  end

  defp maybe_put_heartbeat_env(entries, nil), do: entries

  defp maybe_put_heartbeat_env(entries, json) do
    key = "SNAKEPIT_HEARTBEAT_CONFIG"

    filtered =
      Enum.reject(entries, fn {existing_key, _value} ->
        String.downcase(existing_key) == String.downcase(key)
      end)

    [{key, json} | filtered]
  end

  defp to_env_tuple({key, value}) do
    {String.to_charlist(key), String.to_charlist(value)}
  end

  # CRITICAL FIX: Defensive port cleanup that handles all exit scenarios
  defp safe_close_port(port) do
    try do
      Port.close(port)
    rescue
      # ArgumentError is raised if the port is already closed
      ArgumentError -> :ok
      # Catch any other exceptions
      _ -> :ok
    catch
      # Handle exits (e.g., from brutal :kill)
      :exit, _ -> :ok
      # Handle throws
      :throw, _ -> :ok
    end
  end

  # Private functions

  ##
  # defp wait_for_server_ready(port, expected_port, timeout) do
  #   receive do
  #     {^port, {:data, data}} ->
  #       output = to_string(data)

  #       cond do
  #         String.contains?(output, "gRPC Bridge started") ->
  #           SLog.info("gRPC worker started successfully on port #{expected_port}")
  #           SLog.info("gRPC server output: #{String.trim(output)}")
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

  # Drain remaining output from port buffer to capture error messages
  defp drain_port_buffer(port, timeout) do
    drain_port_buffer(port, timeout, [])
  end

  defp drain_port_buffer(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        output = to_string(data)
        drain_port_buffer(port, timeout, [output | acc])
    after
      timeout ->
        # No more data, return accumulated output
        acc
        |> Enum.reverse()
        |> Enum.join("")
        |> String.trim()
    end
  end

  defp wait_for_server_ready(port, timeout) do
    receive do
      {^port, {:data, data}} ->
        output = to_string(data)

        # Log any output for debugging
        if String.trim(output) != "" do
          SLog.debug("Python server output during startup: #{String.trim(output)}")
        end

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

      {^port, {:exit_status, status}} ->
        # Exit status 143 is SIGTERM (128 + 15) - normal during shutdown, don't alarm
        # Exit status 137 is SIGKILL (128 + 9) - cleanup, don't alarm
        # Exit status 0 is graceful exit
        if status in [0, 137, 143] do
          SLog.debug(
            "Python gRPC server process exited with status #{status} during startup (shutdown)"
          )
        else
          SLog.error("Python gRPC server process exited with status #{status} during startup")
        end

        {:error, {:exit_status, status}}

      {:DOWN, _ref, :port, ^port, reason} ->
        SLog.error("Python gRPC server port died during startup: #{inspect(reason)}")
        {:error, {:port_died, reason}}
    after
      timeout ->
        SLog.error("Timeout waiting for Python gRPC server to start after #{timeout}ms")
        {:error, :timeout}
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

  defp instrument_execute(kind, state, command, args, timeout, fun) when is_function(fun, 1) do
    correlation_id = correlation_id_from(args)
    metadata = base_execute_metadata(kind, state, command, args, correlation_id, timeout)
    span_name = otel_span_name(kind, command)
    span_attributes = otel_start_attributes(state, command, args, correlation_id, timeout)

    :telemetry.span([:snakepit, :grpc_worker, kind], metadata, fn ->
      Tracer.with_span span_name, %{attributes: span_attributes, kind: :client} do
        start_time = System.monotonic_time()
        result = fun.(args)

        duration_native = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

        measurements =
          %{duration_ms: duration_ms, executions: 1}
          |> maybe_track_error_measurement(result)

        stop_metadata = build_stop_metadata(metadata, result)

        Tracer.set_attributes(otel_stop_attributes(result, duration_ms, stop_metadata))
        maybe_set_span_status(result, stop_metadata)

        {result, measurements, stop_metadata}
      end
    end)
  end

  defp build_stop_metadata(metadata, {:error, {kind, reason}}) do
    metadata
    |> Map.put(:status, :error)
    |> Map.put(:error_kind, kind)
    |> Map.put(:error, reason)
  end

  defp build_stop_metadata(metadata, {:error, reason}) do
    metadata
    |> Map.put(:status, :error)
    |> Map.put(:error, reason)
  end

  defp build_stop_metadata(metadata, _result) do
    Map.put(metadata, :status, :ok)
  end

  defp maybe_track_error_measurement(measurements, {:error, _reason}) do
    Map.put(measurements, :errors, 1)
  end

  defp maybe_track_error_measurement(measurements, _result), do: measurements

  defp ensure_correlation(nil) do
    id = Correlation.new_id()
    %{"correlation_id" => id, correlation_id: id}
  end

  defp ensure_correlation(args) when is_map(args) do
    existing =
      Map.get(args, :correlation_id) ||
        Map.get(args, "correlation_id")

    id = Correlation.ensure(existing)

    args
    |> Map.put(:correlation_id, id)
    |> Map.put("correlation_id", id)
  end

  defp ensure_correlation(args) when is_list(args) do
    args
    |> Map.new()
    |> ensure_correlation()
  end

  defp correlation_id_from(%{} = args) do
    args
    |> Map.get(:correlation_id)
    |> case do
      nil -> Map.get(args, "correlation_id")
      value -> value
    end
    |> Correlation.ensure()
  end

  defp base_execute_metadata(kind, state, command, args, correlation_id, timeout) do
    session_id =
      Map.get(args, :session_id) ||
        Map.get(args, "session_id") ||
        state.session_id

    %{
      operation: kind,
      worker_id: state.id,
      worker_pid: self(),
      command: command,
      adapter: adapter_name(state.adapter),
      adapter_module: state.adapter,
      pool: state.pool_name,
      session_id: session_id,
      correlation_id: correlation_id,
      timeout_ms: timeout,
      span_kind: :client,
      rpc_system: :grpc,
      telemetry_source: :snakepit_grpc_worker
    }
  end

  defp otel_span_name(kind, command) do
    operation = kind |> Atom.to_string() |> String.replace("_", "-")
    "snakepit.grpc.#{operation}.#{command}"
  end

  defp otel_start_attributes(state, command, args, correlation_id, timeout) do
    session_id = Map.get(args, :session_id) || Map.get(args, "session_id") || state.session_id

    [
      {"snakepit.worker.id", state.id},
      {"snakepit.pool", pool_attribute(state.pool_name)},
      {"snakepit.command", command},
      {"snakepit.session_id", session_id},
      {"snakepit.correlation_id", correlation_id},
      {"snakepit.timeout_ms", timeout}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp otel_stop_attributes(result, duration_ms, metadata) do
    [
      {"snakepit.grpc.duration_ms", duration_ms},
      {"snakepit.grpc.status", metadata[:status]},
      {"snakepit.grpc.error", format_reason(metadata[:error] || error_from_result(result))},
      {"snakepit.grpc.error_kind", metadata[:error_kind]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp maybe_set_span_status({:error, _}, metadata) do
    reason = format_reason(metadata[:error]) || "snakepit.grpc.error"
    Tracer.set_status(:error, reason)
  end

  defp maybe_set_span_status(_result, _metadata), do: :ok

  defp pool_attribute(nil), do: nil
  defp pool_attribute(pool) when is_atom(pool), do: Atom.to_string(pool)
  defp pool_attribute(pool), do: inspect(pool)

  defp format_reason(nil), do: nil
  defp format_reason({kind, reason}), do: "#{inspect(kind)}: #{inspect(reason)}"
  defp format_reason(reason), do: inspect(reason)

  defp error_from_result({:error, {kind, reason}}), do: {kind, reason}
  defp error_from_result({:error, reason}), do: reason
  defp error_from_result(_), do: nil

  defp adapter_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp adapter_name(other), do: inspect(other)
end
