defmodule Snakepit.Pool.Worker do
  @moduledoc """
  GenServer that manages a single external process via Port using adapter pattern.

  Each worker:
  - Owns one external process (Python, Node.js, etc.)
  - Handles request/response communication via adapter
  - Manages health checks
  - Reports metrics
  """

  use GenServer, restart: :permanent
  require Logger

  alias Snakepit.Bridge.Protocol

  @health_check_interval 30_000
  @init_timeout 20_000

  defstruct [
    :id,
    :port,
    :process_pid,
    :fingerprint,
    :start_time,
    :busy,
    :pending_requests,
    :health_status,
    :last_health_check,
    :stats,
    :adapter_module
  ]

  # Client API

  @doc """
  Starts a worker process.
  """
  def start_link(opts) do
    worker_id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Snakepit.Pool.Registry.via_tuple(worker_id))
  end

  @doc """
  Executes a command on the worker.
  """
  def execute(worker_id, command, args, timeout \\ 30_000) do
    GenServer.call(
      Snakepit.Pool.Registry.via_tuple(worker_id),
      {:execute, command, args},
      timeout
    )
  end

  @doc """
  Checks if a worker is busy.
  """
  def busy?(worker_id) do
    GenServer.call(Snakepit.Pool.Registry.via_tuple(worker_id), :busy?)
  end

  @doc """
  Gets worker statistics.
  """
  def get_stats(worker_id) do
    GenServer.call(Snakepit.Pool.Registry.via_tuple(worker_id), :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :id)
    adapter_module = Application.get_env(:snakepit, :adapter_module)
    
    if adapter_module == nil do
      {:stop, {:error, :no_adapter_configured}}
    else
      fingerprint = generate_fingerprint(worker_id)

      # Start external process using adapter
      case start_external_port(fingerprint, adapter_module) do
        {:ok, port, process_pid} ->
          state = %__MODULE__{
            id: worker_id,
            port: port,
            process_pid: process_pid,
            fingerprint: fingerprint,
            start_time: System.system_time(:second),
            busy: false,
            pending_requests: %{},
            health_status: :initializing,
            stats: %{requests: 0, errors: 0, total_time: 0},
            adapter_module: adapter_module
          }

          # Register worker with process tracking
          Snakepit.Pool.ProcessRegistry.register_worker(
            worker_id,
            self(),
            process_pid,
            fingerprint
          )
          
          # Register with application cleanup for hard guarantee
          if process_pid do
            try do
              Snakepit.Pool.ApplicationCleanup.register_worker_process(process_pid)
            rescue
              _ -> 
                Logger.warning("ApplicationCleanup not available during worker init")
            end
          end

          # Send initialization command asynchronously
          GenServer.cast(self(), :initialize)

          # Return state immediately
          {:ok, state}

        {:error, reason} ->
          {:stop, {:failed_to_start_port, reason}}
      end
    end
  end

  @impl true
  def handle_cast(:initialize, state) do
    Logger.info("🔄 Worker #{state.id} starting initialization with process PID #{state.process_pid}")
    
    # Send initialization ping
    request_id = System.unique_integer([:positive])

    request =
      Protocol.encode_request(request_id, "ping", %{
        "worker_id" => state.id,
        "initialization" => true
      })

    Logger.debug("📤 Worker #{state.id} sending init ping with request_id #{request_id}")

    case Port.command(state.port, request) do
      true ->
        # Set a timer for the initialization timeout
        # We'll use the request_id to correlate the timeout message
        Process.send_after(self(), {:initialization_timeout, request_id}, @init_timeout)
        
        # Track the ping request so we can validate it in handle_info
        pending_reqs = Map.put(state.pending_requests, request_id, {:init, self()})
        {:noreply, %{state | pending_requests: pending_reqs}}

      false ->
        {:stop, :port_command_failed, state}
    end
  end

  @impl true
  def handle_cast(:prepare_shutdown, state) do
    Logger.info("Worker #{state.id} preparing for graceful shutdown")
    {:noreply, state}
  end

  @impl true
  def handle_call({:execute, _command, _args}, _from, %{busy: true} = state) do
    # Worker is busy, reject the request
    {:reply, {:error, :worker_busy}, state}
  end

  def handle_call({:execute, command, args}, from, state) do
    request_id = System.unique_integer([:positive])

    Logger.debug(
      "Worker #{state.id} executing command: #{command} with request_id: #{request_id}"
    )

    # Encode and send request
    request = Protocol.encode_request(request_id, command, args)

    case Port.command(state.port, request) do
      true ->
        # Track pending request
        pending = Map.put(state.pending_requests, request_id, {from, System.monotonic_time()})

        Logger.debug(
          "Worker #{state.id} sent request #{request_id}, pending count: #{map_size(pending)}"
        )

        {:noreply, %{state | busy: true, pending_requests: pending}}

      false ->
        {:reply, {:error, :port_command_failed}, state}
    end
  end

  def handle_call(:busy?, _from, state) do
    {:reply, state.busy, state}
  end

  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:get_process_pid, _from, state) do
    {:reply, state.process_pid, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("Worker #{state.id} received data from port")

    case Protocol.decode_response(data) do
      {:ok, request_id, result} ->
        Logger.debug(
          "Worker #{state.id} decoded response for request #{request_id}: #{inspect(result)}"
        )

        handle_response(request_id, {:ok, result}, state)

      {:error, request_id, error} ->
        Logger.debug(
          "Worker #{state.id} decoded error for request #{request_id}: #{inspect(error)}"
        )

        handle_response(request_id, {:error, error}, state)

      other ->
        Logger.error("Worker #{state.id} - Invalid response from external process: #{inspect(other)}")
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("🔥 Worker #{state.id} port exited: #{inspect(reason)}")
    Logger.error("   Process PID: #{state.process_pid}")
    Logger.error("   Worker was in state: #{state.health_status}")
    {:stop, {:port_exited, reason}, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Status 137 = SIGKILL, which happens during normal pool shutdown
    if status == 137 do
      Logger.debug("Worker #{state.id} terminated by pool shutdown (status 137)")
    else
      Logger.error("🔥 Worker #{state.id} port exited with status #{status}")
      Logger.error("   Process PID: #{state.process_pid}")
      Logger.error("   Worker was in state: #{state.health_status}")
      
      # Check if external process is still alive
      if state.process_pid do
        case System.cmd("kill", ["-0", "#{state.process_pid}"], stderr_to_stdout: true) do
          {_, 0} -> 
            Logger.error("   ⚠️ External process #{state.process_pid} is STILL ALIVE after port death!")
          {_, _} -> 
            Logger.error("   💀 External process #{state.process_pid} is dead")
        end
      end
    end
    
    {:stop, {:port_exit, status}, state}
  end

  def handle_info(:health_check, state) do
    # Send health check ping
    request_id = System.unique_integer([:positive])
    request = Protocol.encode_request(request_id, "ping", %{"health_check" => true})

    case Port.command(state.port, request) do
      true ->
        # Store health check request
        pending =
          Map.put(state.pending_requests, request_id, {:health_check, System.monotonic_time()})

        Process.send_after(self(), :health_check, @health_check_interval)
        {:noreply, %{state | pending_requests: pending}}

      false ->
        # Port is dead
        {:stop, :health_check_failed, state}
    end
  end

  # Handle initialization timeout
  def handle_info({:initialization_timeout, request_id}, state) do
    # Check if the init request is still pending. If so, we timed out.
    if Map.has_key?(state.pending_requests, request_id) do
      Logger.error("⏰ Worker #{state.id} initialization timeout after #{@init_timeout}ms")
      Logger.error("   Process PID: #{state.process_pid}")
      Logger.error("   Port info: #{inspect(Port.info(state.port))}")
      {:stop, :initialization_timeout, state}
    else
      # The response arrived just in time. Ignore the timeout.
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Worker #{state.id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end


  @impl true
  def terminate(reason, state) do
    # Don't log warnings for normal pool shutdown (port exit with status 137)
    case reason do
      {:port_exit, 137} ->
        Logger.debug("Worker #{state.id} terminated by pool shutdown")
      _ ->
        Logger.warning("🔥 Worker #{state.id} terminating: #{inspect(reason)}")
    end

    # Unregister from process tracking
    Snakepit.Pool.ProcessRegistry.unregister_worker(state.id)
    
    # Unregister from application cleanup tracking
    if state.process_pid do
      try do
        Snakepit.Pool.ApplicationCleanup.unregister_worker_process(state.process_pid)
      rescue
        _ -> :ok  # ApplicationCleanup may have already shutdown
      end
    end

    # Always kill external process when worker terminates
    # ApplicationCleanup provides the hard guarantee for app shutdown
    if state.port && Port.info(state.port) do
      # Get the external process PID before closing port
      process_pid = case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> state.process_pid  # Fallback to stored PID
      end
      
      # Close the port first
      Port.close(state.port)
      
      # Then kill the external process if we have its PID
      if process_pid do
        terminate_external_process(process_pid, state.id)
      end
    end

    :ok
  end

  # Private Functions

  defp start_external_port(_fingerprint, adapter_module) do
    executable_path = adapter_module.executable_path()
    script_path = adapter_module.script_path()
    script_args = adapter_module.script_args()

    # Use packet mode for structured communication
    port_opts = [
      :binary,
      :exit_status,
      {:packet, 4},
      {:args, [script_path | script_args]}
    ]

    try do
      port = Port.open({:spawn_executable, executable_path}, port_opts)
      
      # Extract external process PID
      process_pid = case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end
      
      {:ok, port, process_pid}
    rescue
      e -> {:error, e}
    end
  end

  defp generate_fingerprint(worker_id) do
    timestamp = System.system_time(:nanosecond)
    random = :rand.uniform(1_000_000)
    "snakepit_worker_#{worker_id}_#{timestamp}_#{random}"
  end

  defp terminate_external_process(process_pid, worker_id) when is_integer(process_pid) do
    Logger.warning("🔥 Terminating external process #{process_pid} for worker #{worker_id}")
    
    try do
      # Try graceful termination first
      case System.cmd("kill", ["-TERM", "#{process_pid}"], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.warning("✅ Sent SIGTERM to external process #{process_pid}")
          
          # Wait for graceful shutdown using process monitoring instead of sleep
          wait_for_process_termination(process_pid, 500)
          
        {_error, _} ->
          # Process already dead or kill failed
          Logger.warning("⚠️ External process #{process_pid} already dead or kill failed")
      end
    rescue
      e ->
        Logger.warning("💥 Exception killing external process #{process_pid}: #{inspect(e)}")
    end
  end

  defp terminate_external_process(nil, worker_id) do
    Logger.warning("⚠️ No external process PID to terminate for worker #{worker_id}")
  end

  # Wait for external process termination using proper process monitoring
  defp wait_for_process_termination(process_pid, timeout_ms) do
    # Spawn a task to monitor the process and force kill if needed
    task = Task.async(fn ->
      case wait_for_pid_exit(process_pid, timeout_ms) do
        :exited ->
          Logger.warning("✅ External process #{process_pid} exited gracefully")
          :ok
        :timeout ->
          Logger.warning("⚠️ External process #{process_pid} did not exit gracefully, force killing")
          # Force kill if still alive
          case System.cmd("kill", ["-KILL", "#{process_pid}"], stderr_to_stdout: true) do
            {_output, 0} ->
              Logger.warning("✅ Force killed external process #{process_pid}")
            {_error, _} ->
              Logger.warning("⚠️ External process #{process_pid} already dead")
          end
          :force_killed
      end
    end)
    
    # Wait for the task with a reasonable timeout
    case Task.yield(task, timeout_ms + 100) do
      {:ok, result} -> result
      nil -> 
        Task.shutdown(task, :brutal_kill)
        Logger.warning("⚠️ Timeout waiting for process #{process_pid} termination")
        :timeout
    end
  end

  # Check if a PID is still alive using OS-level process checking with proper OTP timing
  defp wait_for_pid_exit(process_pid, timeout_ms) do
    # Use a timer-based approach instead of sleep loops
    start_time = System.monotonic_time(:millisecond)
    check_interval = 50
    
    wait_for_pid_exit_with_timer(process_pid, start_time, timeout_ms, check_interval)
  end

  defp wait_for_pid_exit_with_timer(process_pid, start_time, timeout_ms, check_interval) do
    current_time = System.monotonic_time(:millisecond)
    
    if current_time - start_time >= timeout_ms do
      :timeout
    else
      # Check if process is still alive using kill -0 (no signal sent, just check)
      case System.cmd("kill", ["-0", "#{process_pid}"], stderr_to_stdout: true) do
        {_output, 0} ->
          # Process still alive, use receive with timer instead of sleep
          receive do
          after check_interval ->
            wait_for_pid_exit_with_timer(process_pid, start_time, timeout_ms, check_interval)
          end
        {_error, _} ->
          # Process no longer exists
          :exited
      end
    end
  end

  defp handle_response(request_id, result, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        # Unknown request ID
        Logger.warning("Received response for unknown request: #{request_id}. Pending requests: #{inspect(Map.keys(state.pending_requests))}")
        {:noreply, state}

      {{:health_check, start_time}, pending} ->
        # Health check response
        _duration = System.monotonic_time() - start_time

        health_status =
          case result do
            {:ok, _} -> :healthy
            {:error, _} -> :unhealthy
          end

        {:noreply,
         %{
           state
           | pending_requests: pending,
             health_status: health_status,
             last_health_check: System.monotonic_time()
         }}

      {{:init, _}, pending} ->
        # Initialization response
        handle_initialization_response(request_id, result, %{state | pending_requests: pending})

      {{from, start_time}, pending} ->
        # Regular request response
        duration = System.monotonic_time() - start_time

        # Update stats
        stats = update_stats(state.stats, result, duration)

        # Reply to caller
        GenServer.reply(from, result)

        {:noreply, %{state | busy: false, pending_requests: pending, stats: stats}}
    end
  end

  defp update_stats(stats, result, duration) do
    stats
    |> Map.update!(:requests, &(&1 + 1))
    |> Map.update!(:errors, fn errors ->
      case result do
        {:ok, _} -> errors
        {:error, _} -> errors + 1
      end
    end)
    |> Map.update!(:total_time, &(&1 + duration))
  end

  # Handle initialization response logic
  defp handle_initialization_response(_request_id, {:ok, response}, state) do
    if Map.get(response, "status") == "ok" do
      Logger.info("✅ Worker #{state.id} initialized successfully")

      # Schedule health checks
      Process.send_after(self(), :health_check, @health_check_interval)

      {:noreply, %{state | health_status: :healthy}}
    else
      Logger.error("Failed to initialize worker: #{inspect(response)}")
      {:stop, {:initialization_failed, response}, state}
    end
  end

  defp handle_initialization_response(_request_id, error, state) do
    Logger.error("Failed to initialize worker: #{inspect(error)}")
    {:stop, {:initialization_failed, error}, state}
  end
end