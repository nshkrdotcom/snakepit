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
        handle_chunk(chunk)
      end)
  """

  use GenServer
  require Logger
  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.Error
  alias Snakepit.GRPCWorker.Bootstrap
  alias Snakepit.GRPCWorker.Instrumentation
  alias Snakepit.GRPC.Client
  alias Snakepit.Internal.AsyncFallback
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Logger.Redaction
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Shutdown
  alias Snakepit.Telemetry.GrpcStream
  alias Snakepit.Worker.Configuration
  alias Snakepit.Worker.LifecycleManager
  alias Snakepit.Worker.ProcessManager

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker,
      # Must give worker time for graceful Python shutdown.
      # Derived from :graceful_shutdown_timeout_ms + margin.
      shutdown: supervisor_shutdown_timeout()
    }
  end

  @type worker_state :: %{
          adapter: module(),
          connection: map() | nil,
          port: integer(),
          process_pid: integer() | nil,
          pgid: integer() | nil,
          process_group?: boolean(),
          server_port: port() | nil,
          id: String.t(),
          pool_name: atom() | pid(),
          health_check_ref: reference() | nil,
          heartbeat_monitor: pid() | nil,
          heartbeat_config: map(),
          ready_file: String.t(),
          stats: map(),
          session_id: String.t(),
          worker_config: map(),
          shutting_down: boolean(),
          rpc_request_queue: :queue.queue(map()),
          pending_rpc_calls: map(),
          pending_rpc_monitors: map()
        }
  @log_category :grpc

  # Client API

  @doc """
  Start a gRPC worker with the given adapter.
  """
  def start_link(opts) do
    worker_id = Keyword.get(opts, :id)
    pool_name = Keyword.get(opts, :pool_name, Snakepit.Pool)

    pool_identifier = Configuration.resolve_pool_identifier(opts, pool_name)

    metadata =
      %{worker_module: __MODULE__, pool_name: pool_name}
      |> maybe_put_pool_identifier(pool_identifier)

    opts_with_metadata =
      opts
      |> Keyword.put(:registry_metadata, metadata)
      |> maybe_put_pool_identifier_opt(pool_identifier)

    name = build_worker_name(worker_id)

    GenServer.start_link(__MODULE__, opts_with_metadata, name: name)
  end

  @doc """
  Execute a command and return the result.
  """
  # Header for default values
  def execute(worker, command, args, timeout_or_opts \\ nil)

  def execute(worker, command, args, nil) do
    execute(worker, command, args, Defaults.grpc_worker_execute_timeout(), [])
  end

  def execute(worker, command, args, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.grpc_worker_execute_timeout())
    execute(worker, command, args, timeout, opts)
  end

  def execute(worker, command, args, timeout) when is_integer(timeout) or timeout == :infinity do
    execute(worker, command, args, timeout, [])
  end

  def execute(worker_id, command, args, timeout, opts) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:execute, command, args, timeout, opts}, call_timeout(timeout))

      {:error, _} ->
        {:error,
         Error.worker_error("Worker not found", %{worker_id: worker_id, command: command})}
    end
  end

  def execute(worker_pid, command, args, timeout, opts) when is_pid(worker_pid) do
    GenServer.call(worker_pid, {:execute, command, args, timeout, opts}, call_timeout(timeout))
  end

  @doc """
  Execute a streaming command with callback.
  """
  def execute_stream(worker, command, args, callback_fn, timeout_or_opts \\ nil)

  def execute_stream(worker, command, args, callback_fn, nil) do
    execute_stream(worker, command, args, callback_fn, Defaults.grpc_worker_stream_timeout(), [])
  end

  def execute_stream(worker, command, args, callback_fn, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.grpc_worker_stream_timeout())
    execute_stream(worker, command, args, callback_fn, timeout, opts)
  end

  def execute_stream(worker, command, args, callback_fn, timeout)
      when is_integer(timeout) or timeout == :infinity do
    execute_stream(worker, command, args, callback_fn, timeout, [])
  end

  def execute_stream(worker_id, command, args, callback_fn, timeout, opts)
      when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(
          pid,
          {:execute_stream, command, args, callback_fn, timeout, opts},
          call_timeout(timeout)
        )

      {:error, _} ->
        {:error,
         Error.worker_error("Worker not found", %{worker_id: worker_id, command: command})}
    end
  end

  def execute_stream(worker_pid, command, args, callback_fn, timeout, opts)
      when is_pid(worker_pid) do
    GenServer.call(
      worker_pid,
      {:execute_stream, command, args, callback_fn, timeout, opts},
      call_timeout(timeout)
    )
  end

  @doc """
  Execute a command in a specific session.
  """
  def execute_in_session(worker, session_id, command, args, timeout_or_opts \\ nil)

  def execute_in_session(worker, session_id, command, args, nil) do
    execute_in_session(
      worker,
      session_id,
      command,
      args,
      Defaults.grpc_worker_execute_timeout(),
      []
    )
  end

  def execute_in_session(worker, session_id, command, args, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.grpc_worker_execute_timeout())
    execute_in_session(worker, session_id, command, args, timeout, opts)
  end

  def execute_in_session(worker, session_id, command, args, timeout)
      when is_integer(timeout) or timeout == :infinity do
    execute_in_session(worker, session_id, command, args, timeout, [])
  end

  def execute_in_session(worker, session_id, command, args, timeout, opts) do
    GenServer.call(
      worker,
      {:execute_session, session_id, command, args, timeout, opts},
      call_timeout(timeout)
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

  defp build_worker_name(nil), do: nil

  defp build_worker_name(worker_id) do
    {:via, Registry, {Snakepit.Pool.Registry, worker_id}}
  end

  defp maybe_put_pool_identifier(metadata, nil), do: metadata

  defp maybe_put_pool_identifier(metadata, identifier),
    do: Map.put(metadata, :pool_identifier, identifier)

  defp maybe_put_pool_identifier_opt(opts, nil), do: opts

  defp maybe_put_pool_identifier_opt(opts, identifier),
    do: Keyword.put(opts, :pool_identifier, identifier)

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout), do: timeout + 1_000

  defp current_process_memory_bytes do
    case Process.info(self(), :memory) do
      {:memory, bytes} when is_integer(bytes) and bytes >= 0 -> bytes
      _ -> 0
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Bootstrap.init(opts)
  end

  defp complete_worker_initialization(state, connection, actual_port) do
    health_ref = schedule_health_check()

    LifecycleManager.track_worker(state.pool_name, state.id, self(), state.worker_config)

    SLog.info(
      @log_category,
      "✅ gRPC worker #{state.id} initialization complete and acknowledged."
    )

    maybe_initialize_session(connection, state.session_id)
    register_telemetry_stream(connection, state)
    Instrumentation.emit_worker_spawned_telemetry(state, actual_port)

    new_state =
      state
      |> Map.put(:connection, connection)
      |> Map.put(:port, actual_port)
      |> Map.put(:health_check_ref, health_ref)
      |> maybe_start_heartbeat_monitor()

    {:noreply, new_state}
  end

  @impl true
  def handle_continue(:connect_and_wait, state) do
    Bootstrap.connect_and_wait(state, &complete_worker_initialization/3)
  end

  @impl true
  def handle_call({:execute, command, args, timeout}, from, state) do
    handle_call({:execute, command, args, timeout, []}, from, state)
  end

  def handle_call({:execute, command, args, timeout, opts}, from, state) do
    args_with_corr = Instrumentation.ensure_correlation(args)

    enqueue_async_rpc_call(from, state, fn ->
      execute_call_result(state, command, args_with_corr, timeout, opts)
    end)
  end

  @impl true
  def handle_call({:execute_stream, command, args, callback_fn, timeout}, from, state) do
    handle_call({:execute_stream, command, args, callback_fn, timeout, []}, from, state)
  end

  def handle_call({:execute_stream, command, args, callback_fn, timeout, opts}, from, state) do
    SLog.debug(
      @log_category,
      "[GRPCWorker] execute_stream #{command} with args #{Redaction.describe(args)}"
    )

    args_with_corr = Instrumentation.ensure_correlation(args)

    enqueue_async_rpc_call(from, state, fn ->
      execute_stream_call_result(state, command, args_with_corr, callback_fn, timeout, opts)
    end)
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
  def handle_call({:execute_session, session_id, command, args, timeout}, from, state) do
    handle_call({:execute_session, session_id, command, args, timeout, []}, from, state)
  end

  def handle_call({:execute_session, session_id, command, args, timeout, opts}, from, state) do
    session_args =
      args
      |> Map.put(:session_id, session_id)
      |> Instrumentation.ensure_correlation()

    enqueue_async_rpc_call(from, state, fn ->
      execute_session_call_result(state, session_args, command, timeout, opts)
    end)
  end

  @impl true
  def handle_call(:get_health, from, state) do
    enqueue_async_rpc_call(from, state, fn ->
      {make_health_check(state), :none}
    end)
  end

  @impl true
  def handle_call(:get_info, from, state) do
    enqueue_async_rpc_call(from, state, fn ->
      {make_info_call(state), :none}
    end)
  end

  @impl true
  def handle_call(:get_channel, _from, state) do
    if state.connection do
      {:reply, {:ok, state.connection.channel}, state}
    else
      {:reply,
       {:error,
        Error.grpc_error(:not_connected, "Not connected to gRPC server", %{worker_id: state.id})},
       state}
    end
  end

  @impl true
  def handle_call(:get_session_id, _from, state) do
    {:reply, {:ok, state.session_id}, state}
  end

  def handle_call(:get_memory_usage, _from, state) do
    {:reply, {:ok, current_process_memory_bytes()}, state}
  end

  @impl true
  def handle_info({:grpc_async_rpc_result, token, {:ok, {reply, stat_result}}}, state) do
    case pop_pending_rpc_call(state, token) do
      {:ok, pending_call, new_state} ->
        Process.demonitor(pending_call.monitor_ref, [:flush])
        maybe_reply_pending_call(pending_call.from, reply)
        {:noreply, new_state |> update_stats(stat_result) |> maybe_start_next_rpc_call()}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:grpc_async_rpc_result, token, {:exception, error, stacktrace}}, state) do
    case pop_pending_rpc_call(state, token) do
      {:ok, pending_call, new_state} ->
        Process.demonitor(pending_call.monitor_ref, [:flush])

        SLog.error(
          @log_category,
          "Async gRPC request failed with exception: #{Exception.message(error)}",
          stacktrace: stacktrace
        )

        reply =
          {:error,
           Error.worker_error("Async gRPC request failed", %{
             worker_id: state.id,
             exception: Exception.message(error)
           })}

        maybe_reply_pending_call(pending_call.from, reply)
        {:noreply, new_state |> update_stats(:error) |> maybe_start_next_rpc_call()}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:grpc_async_rpc_result, token, {:caught, kind, reason, stacktrace}}, state) do
    case pop_pending_rpc_call(state, token) do
      {:ok, pending_call, new_state} ->
        Process.demonitor(pending_call.monitor_ref, [:flush])

        SLog.error(
          @log_category,
          "Async gRPC request failed with #{inspect(kind)}: #{inspect(reason)}",
          stacktrace: stacktrace
        )

        reply =
          {:error,
           Error.worker_error("Async gRPC request failed", %{
             worker_id: state.id,
             kind: kind,
             reason: reason
           })}

        maybe_reply_pending_call(pending_call.from, reply)
        {:noreply, new_state |> update_stats(:error) |> maybe_start_next_rpc_call()}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, :normal}, state) do
    if pending_rpc_monitor?(state, monitor_ref) do
      # Completion message may still be in flight from async callback worker.
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case pop_pending_rpc_by_monitor(state, monitor_ref) do
      {:ok, pending_call, new_state} ->
        reply =
          {:error,
           Error.worker_error("Async gRPC request process exited", %{
             worker_id: state.id,
             reason: reason
           })}

        maybe_reply_pending_call(pending_call.from, reply)
        {:noreply, new_state |> update_stats(:error) |> maybe_start_next_rpc_call()}

      {:error, new_state} ->
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, _task_result}, state) when is_reference(ref) do
    # async_nolink emits `{ref, result}` on completion. We keep the existing
    # custom message contract (`:grpc_async_rpc_result`) for downstream handling.
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    health_ref = schedule_health_check()

    {:noreply,
     state
     |> Map.put(:health_check_ref, health_ref)
     |> enqueue_periodic_health_check()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :port, port, reason}, %{server_port: port} = state) do
    # Use same shutdown detection as exit_status handler to avoid race conditions.
    # :DOWN can arrive before or instead of exit_status on some platforms.
    effective_shutting_down? =
      state.shutting_down or
        shutdown_pending_in_mailbox?() or
        not pool_alive?(state.pool_name) or
        Shutdown.in_progress?() or
        system_stopping?()

    state =
      if effective_shutting_down? and not state.shutting_down do
        %{state | shutting_down: true}
      else
        state
      end

    if effective_shutting_down? do
      SLog.debug(@log_category, """
      gRPC port DOWN during shutdown
      Worker: #{state.id}
      Reason: #{inspect(reason)}
      """)

      {:stop, :shutdown, state}
    else
      SLog.error(@log_category, """
      External gRPC process died unexpectedly
      Worker: #{state.id}
      Reason: #{inspect(reason)}
      """)

      {:stop, {:external_process_died, reason}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, monitor_pid, exit_reason}, %{heartbeat_monitor: monitor_pid} = state) do
    SLog.warning(
      @log_category,
      "Heartbeat monitor for #{state.id} exited with #{inspect(exit_reason)}; terminating worker"
    )

    {:stop, {:shutdown, exit_reason}, %{state | heartbeat_monitor: nil}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{server_port: port} = state) do
    output = to_string(data)
    buffer = ProcessManager.append_startup_output(state.python_output_buffer, output)

    if log_python_output?() do
      trimmed = String.trim(output)

      if trimmed != "" do
        SLog.info(@log_category, "gRPC server output: #{trimmed}")
      end
    end

    {:noreply, %{state | python_output_buffer: buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{server_port: port} = state) do
    # DIAGNOSTIC: Drain any remaining error output from the port buffer
    remaining_output = ProcessManager.drain_port_buffer(port, 200)

    last_output =
      state.python_output_buffer
      |> ProcessManager.append_startup_output(remaining_output)
      |> String.trim()

    last_output =
      if last_output == "" do
        "<no output>"
      else
        last_output
      end

    # Compute effective shutdown status to handle mailbox race conditions.
    # The port exit message may arrive before the {:EXIT, _, :shutdown} message is processed.
    # We check multiple signals to determine if we're in a shutdown scenario:
    # 1. state.shutting_down was already set
    # 2. A shutdown EXIT message is pending in the mailbox
    # 3. The pool is no longer alive (system is shutting down)
    effective_shutting_down? =
      state.shutting_down or
        shutdown_pending_in_mailbox?() or
        not pool_alive?(state.pool_name) or
        Shutdown.in_progress?() or
        system_stopping?()

    # Update state if we detected shutdown via mailbox peek or pool check
    state =
      if effective_shutting_down? and not state.shutting_down do
        %{state | shutting_down: true}
      else
        state
      end

    # Shutdown exit codes: 0 (clean), 143 (SIGTERM: 128+15), 137 (SIGKILL: 128+9)
    # These are expected during shutdown and should not be treated as errors.
    case {status, effective_shutting_down?} do
      {s, true} when s in [0, 137, 143] ->
        # Expected shutdown - Python exited with a normal shutdown code
        SLog.debug(@log_category, """
        Python gRPC server exited during shutdown (status #{s})
        Worker: #{state.id}
        Port: #{state.port}
        PID: #{state.process_pid}
        """)

        {:stop, :shutdown, state}

      {0, false} ->
        # Unexpected but clean exit - Python decided to exit on its own
        # This could be idle timeout, internal shutdown, or other reason
        SLog.warning(@log_category, """
        Python gRPC server exited unexpectedly (status 0)
        Worker: #{state.id}
        Port: #{state.port}
        PID: #{state.process_pid}
        Last output: #{last_output}
        """)

        # Use an abnormal reason so Worker.Starter (with :transient) will restart.
        # This maintains pool capacity when Python exits unexpectedly.
        {:stop, {:grpc_server_exited_unexpectedly, 0}, state}

      {_nonzero, _} ->
        # Real crash - non-zero exit status (not a shutdown code)
        SLog.error(@log_category, """
        🔴 Python gRPC server crashed with status #{status}
        Worker: #{state.id}
        Port: #{state.port}
        PID: #{state.process_pid}
        Last output: #{last_output}
        """)

        {:stop, {:grpc_server_exited, status}, state}
    end
  end

  # Handle shutdown signals from supervisor.
  # Matches both :shutdown and {:shutdown, term} which supervisors use.
  # Does not match :normal since that can come from other linked processes (like Tasks).
  @impl true
  def handle_info({:EXIT, _from, reason}, state) when reason == :shutdown do
    SLog.debug(@log_category, """
    Received shutdown signal for worker #{state.id}
    Reason: #{inspect(reason)}
    Setting shutting_down flag and stopping gracefully
    """)

    {:stop, :shutdown, %{state | shutting_down: true}}
  end

  @impl true
  def handle_info({:EXIT, _from, {:shutdown, term} = reason}, state) do
    SLog.debug(@log_category, """
    Received shutdown signal for worker #{state.id}
    Reason: #{inspect(reason)}
    Setting shutting_down flag and stopping gracefully
    """)

    {:stop, {:shutdown, term}, %{state | shutting_down: true}}
  end

  @impl true
  def handle_info(msg, state) do
    SLog.debug(@log_category, "Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp graceful_shutdown_timeout do
    Defaults.graceful_shutdown_timeout_ms()
  end

  @doc """
  Returns the recommended supervisor shutdown timeout.

  This is `graceful_shutdown_timeout + margin` to ensure supervisors give workers
  enough time to complete their terminate/2 callback (which includes graceful
  Python process termination).

  Use this value for:
  - `shutdown:` in child_spec
  - `shutdown:` in Worker.Starter
  - Any other supervisor that manages GRPCWorker processes

  ## Example

      children = [
        %{
          id: MyWorker,
          start: {Snakepit.GRPCWorker, :start_link, [opts]},
          shutdown: Snakepit.GRPCWorker.supervisor_shutdown_timeout()
        }
      ]
  """
  def supervisor_shutdown_timeout do
    graceful_shutdown_timeout() + Defaults.shutdown_margin_ms()
  end

  @impl true
  def terminate(reason, state) do
    SLog.debug(
      @log_category,
      "GRPCWorker.terminate/2 called for #{state.id}, reason: #{inspect(reason)}, PID: #{state.process_pid}"
    )

    SLog.debug(@log_category, "gRPC worker #{state.id} terminating: #{inspect(reason)}")

    planned? = Shutdown.shutdown_reason?(reason) or reason == :normal
    Instrumentation.emit_worker_terminated_telemetry(state, reason, planned?)
    cancel_pending_rpc_calls(state, reason)
    cleanup_heartbeat(state, reason)
    ProcessManager.kill_python_process(state, reason, graceful_shutdown_timeout())
    ProcessManager.cleanup_ready_file(state.ready_file)
    cleanup_resources(state)

    :ok
  end

  defp cleanup_heartbeat(state, reason) do
    maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
    maybe_notify_test_pid(state.heartbeat_config, {:heartbeat_monitor_stopped, state.id, reason})
  end

  defp cleanup_resources(state) do
    disconnect_connection(state.connection)
    cancel_health_check_timer(state.health_check_ref)
    close_server_port(state.server_port)
    GrpcStream.unregister_worker(state.id)
    ProcessRegistry.unregister_worker(state.id)
  end

  defp cancel_pending_rpc_calls(state, reason) do
    reply =
      {:error,
       Error.worker_error("Worker shutting down", %{
         worker_id: Map.get(state, :id),
         reason: reason
       })}

    state
    |> Map.get(:pending_rpc_calls, %{})
    |> Enum.each(fn {_token, pending_call} ->
      maybe_terminate_task_process(Map.get(pending_call, :task_pid))
      maybe_demonitor_rpc_call(Map.get(pending_call, :monitor_ref))
      maybe_reply_pending_call(Map.get(pending_call, :from), reply)
    end)

    state
    |> Map.get(:rpc_request_queue, :queue.new())
    |> :queue.to_list()
    |> Enum.each(fn request ->
      maybe_reply_pending_call(Map.get(request, :from), reply)
    end)
  end

  defp maybe_terminate_task_process(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_terminate_task_process(_), do: :ok

  defp maybe_demonitor_rpc_call(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp maybe_demonitor_rpc_call(_), do: :ok

  defp cancel_health_check_timer(nil), do: :ok

  defp cancel_health_check_timer(health_check_ref) do
    Process.cancel_timer(health_check_ref, async: true, info: false)
    :ok
  end

  defp close_server_port(nil), do: :ok

  defp close_server_port(server_port) do
    safe_close_port(server_port)
  end

  defp maybe_start_heartbeat_monitor(state) do
    config = Bootstrap.normalize_heartbeat_config(state.heartbeat_config)

    cond do
      not config[:enabled] ->
        maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
        %{state | heartbeat_config: config, heartbeat_monitor: nil}

      heartbeat_monitor_running?(state.heartbeat_monitor) ->
        %{state | heartbeat_config: config}

      state.connection == nil ->
        %{state | heartbeat_config: config}

      not heartbeat_transport_available?(state, config) ->
        SLog.debug(
          @log_category,
          "Skipping heartbeat monitor for #{state.id}: no heartbeat transport available"
        )

        %{state | heartbeat_config: config, heartbeat_monitor: nil}

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
            SLog.error(
              @log_category,
              "Failed to start heartbeat monitor for #{state.id}: #{inspect(reason)}"
            )

            maybe_notify_test_pid(config, {:heartbeat_monitor_failed, state.id, reason})

            %{state | heartbeat_monitor: nil, heartbeat_config: config}
        end
    end
  end

  defp heartbeat_transport_available?(state, config) do
    channel = state.connection && Map.get(state.connection, :channel)

    is_function(config[:ping_fun], 1) or
      function_exported?(state.adapter, :grpc_heartbeat, 3) or
      function_exported?(state.adapter, :grpc_heartbeat, 2) or
      heartbeat_channel_available?(channel)
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
            adapter.grpc_heartbeat(connection, session_id, config)

          function_exported?(adapter, :grpc_heartbeat, 2) ->
            adapter.grpc_heartbeat(connection, session_id)

          heartbeat_channel_available?(channel) ->
            Client.heartbeat(channel, session_id, timeout: config[:timeout_ms])

          true ->
            {:error,
             Error.grpc_error(:no_heartbeat_transport, "No heartbeat transport available", %{
               adapter: adapter,
               session_id: session_id
             })}
        end

      handle_heartbeat_response(self(), timestamp, result)
    end
  end

  defp heartbeat_channel_available?(%{mock: true}), do: true
  defp heartbeat_channel_available?(%GRPC.Channel{}), do: true
  defp heartbeat_channel_available?(_), do: false

  defp maybe_initialize_session(connection, session_id) do
    channel = connection && Map.get(connection, :channel)

    if heartbeat_channel_available?(channel) do
      try do
        _ = Client.initialize_session(channel, session_id, %{})
        :ok
      rescue
        exception ->
          SLog.debug(
            @log_category,
            "Heartbeat session initialization failed: #{inspect(exception)}"
          )

          :error
      catch
        :exit, reason ->
          SLog.debug(@log_category, "Heartbeat session initialization exited: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end

  defp register_telemetry_stream(connection, state) do
    channel = connection && Map.get(connection, :channel)

    if channel do
      try do
        worker_ctx = %{
          worker_id: state.id,
          pool_name: state.pool_name,
          python_pid: state.process_pid
        }

        GrpcStream.register_worker(channel, worker_ctx)
        SLog.debug(@log_category, "Registered telemetry stream for worker #{state.id}")
        :ok
      rescue
        exception ->
          SLog.warning(
            @log_category,
            "Failed to register telemetry stream for worker #{state.id}: #{inspect(exception)}"
          )

          :error
      catch
        :exit, reason ->
          SLog.warning(
            @log_category,
            "Telemetry stream registration exited for worker #{state.id}: #{inspect(reason)}"
          )

          :error
      end
    else
      SLog.debug(@log_category, "No channel available for telemetry stream registration")
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

  defp enqueue_periodic_health_check(state) do
    callback_fun = fn ->
      result = make_health_check(state)

      case result do
        {:ok, _health} ->
          :ok

        {:error, reason} ->
          SLog.warning(@log_category, "Health check failed", reason: reason, worker_id: state.id)
      end

      {result, :none}
    end

    {:noreply, queued_state} = enqueue_async_rpc_call(:none, state, callback_fun)
    queued_state
  end

  defp maybe_stop_heartbeat_monitor(nil), do: :ok

  defp maybe_stop_heartbeat_monitor(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :shutdown)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp disconnect_connection(nil), do: :ok

  defp disconnect_connection(%{channel: %GRPC.Channel{} = channel}) do
    GRPC.Stub.disconnect(channel)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp disconnect_connection(%{channel: channel}) when not is_nil(channel), do: :ok
  defp disconnect_connection(_), do: :ok

  # CRITICAL FIX: Defensive port cleanup that handles all exit scenarios
  defp safe_close_port(port) do
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

  # Private functions

  defp log_python_output? do
    Application.get_env(:snakepit, :log_python_output, false)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, Defaults.grpc_worker_health_check_interval())
  end

  defp make_health_check(state) do
    timeout_ms = Config.grpc_worker_health_check_timeout_ms()

    case Client.health(state.connection.channel, inspect(self()), timeout: timeout_ms) do
      {:ok, health_response} ->
        {:ok, health_response}

      {:error, reason} ->
        {:error,
         Error.grpc_error(:health_check_failed, "Health check failed", %{
           worker_id: state.id,
           reason: reason
         })}
    end
  end

  defp make_info_call(state) do
    case Client.get_info(state.connection.channel) do
      {:ok, info_response} ->
        {:ok, info_response}

      {:error, reason} ->
        {:error,
         Error.grpc_error(:info_failed, "Info call failed", %{
           worker_id: state.id,
           reason: reason
         })}
    end
  end

  defp execute_call_result(state, command, args_with_corr, timeout, opts) do
    execute_instrumented_call_result(:execute, state, command, args_with_corr, timeout, opts)
  end

  defp execute_stream_call_result(state, command, args_with_corr, callback_fn, timeout, opts) do
    result =
      state.adapter.grpc_execute_stream(
        state.connection,
        state.session_id,
        command,
        args_with_corr,
        callback_fn,
        timeout,
        opts
      )

    SLog.debug(@log_category, "[GRPCWorker] execute_stream result: #{Redaction.describe(result)}")

    case result do
      :ok ->
        {:ok, :success}

      {:error, _reason} = error ->
        {error, :error}

      other ->
        SLog.error(
          @log_category,
          "Unexpected gRPC execute_stream result: #{inspect(other)}"
        )

        {other, :error}
    end
  end

  defp execute_session_call_result(state, session_args, command, timeout, opts) do
    execute_instrumented_call_result(
      :execute_session,
      state,
      command,
      session_args,
      timeout,
      opts
    )
  end

  defp execute_instrumented_call_result(operation, state, command, args, timeout, opts)
       when operation in [:execute, :execute_session] do
    case Instrumentation.instrument_execute(
           operation,
           state,
           command,
           args,
           timeout,
           fn instrumented_args ->
             state.adapter.grpc_execute(
               state.connection,
               state.session_id,
               command,
               instrumented_args,
               timeout,
               opts
             )
           end
         ) do
      {:ok, result} ->
        {{:ok, result}, :success}

      {:error, reason} ->
        {{:error, reason}, :error}

      other ->
        SLog.error(
          @log_category,
          "Unexpected gRPC #{operation} result: #{inspect(other)}"
        )

        {{:error, other}, :error}
    end
  end

  defp enqueue_async_rpc_call(from, state, callback_fun) when is_function(callback_fun, 0) do
    request = %{
      from: from,
      callback_fun: callback_fun,
      otel_ctx: :otel_ctx.get_current()
    }

    queue =
      state
      |> Map.get(:rpc_request_queue, :queue.new())
      |> then(&:queue.in(request, &1))

    state =
      state
      |> Map.put(:rpc_request_queue, queue)
      |> maybe_start_next_rpc_call()

    {:noreply, state}
  end

  defp maybe_start_next_rpc_call(state) do
    if map_size(Map.get(state, :pending_rpc_calls, %{})) > 0 do
      state
    else
      queue = Map.get(state, :rpc_request_queue, :queue.new())

      case :queue.out(queue) do
        {{:value, request}, rest_queue} ->
          state
          |> Map.put(:rpc_request_queue, rest_queue)
          |> start_async_rpc_call(request)

        {:empty, _queue} ->
          state
      end
    end
  end

  defp start_async_rpc_call(state, %{from: from, callback_fun: callback_fun, otel_ctx: otel_ctx}) do
    call_token = make_ref()
    parent = self()

    rpc_runner = fn ->
      ctx_token = :otel_ctx.attach(otel_ctx)

      result =
        try do
          {:ok, callback_fun.()}
        rescue
          exception ->
            {:exception, exception, __STACKTRACE__}
        catch
          kind, reason ->
            {:caught, kind, reason, __STACKTRACE__}
        after
          :otel_ctx.detach(ctx_token)
        end

      send(parent, {:grpc_async_rpc_result, call_token, result})
    end

    {task_pid, monitor_ref} = start_nolink_rpc_task(rpc_runner)

    pending_call = %{from: from, monitor_ref: monitor_ref, task_pid: task_pid}

    put_pending_rpc_call(state, call_token, pending_call)
  end

  defp start_nolink_rpc_task(fun) when is_function(fun, 0) do
    {:ok, pid, ref} =
      AsyncFallback.start_nolink_with_fallback(
        Snakepit.TaskSupervisor,
        fun,
        fallback_mode: :fire_and_forget,
        on_fallback: &log_async_rpc_fallback/1
      )

    {pid, ref}
  end

  defp log_async_rpc_fallback({:rescue, error}) do
    SLog.warning(
      @log_category,
      "TaskSupervisor unavailable for async RPC task; using fallback",
      error: error
    )
  end

  defp log_async_rpc_fallback({:exit, reason}) do
    SLog.warning(@log_category, "TaskSupervisor exited for async RPC task; using fallback",
      reason: reason
    )
  end

  defp put_pending_rpc_call(state, token, pending_call) do
    pending_calls = Map.put(Map.get(state, :pending_rpc_calls, %{}), token, pending_call)

    pending_monitors =
      Map.put(
        Map.get(state, :pending_rpc_monitors, %{}),
        pending_call.monitor_ref,
        token
      )

    state
    |> Map.put(:pending_rpc_calls, pending_calls)
    |> Map.put(:pending_rpc_monitors, pending_monitors)
  end

  defp pop_pending_rpc_call(state, token) do
    case Map.pop(Map.get(state, :pending_rpc_calls, %{}), token) do
      {nil, _pending_calls} ->
        :error

      {pending_call, pending_calls} ->
        pending_monitors =
          Map.delete(Map.get(state, :pending_rpc_monitors, %{}), pending_call.monitor_ref)

        new_state =
          state
          |> Map.put(:pending_rpc_calls, pending_calls)
          |> Map.put(:pending_rpc_monitors, pending_monitors)

        {:ok, pending_call, new_state}
    end
  end

  defp pop_pending_rpc_by_monitor(state, monitor_ref) do
    case Map.pop(Map.get(state, :pending_rpc_monitors, %{}), monitor_ref) do
      {nil, _pending_monitors} ->
        :error

      {token, pending_monitors} ->
        case Map.pop(Map.get(state, :pending_rpc_calls, %{}), token) do
          {nil, _pending_calls} ->
            new_state = Map.put(state, :pending_rpc_monitors, pending_monitors)
            {:error, new_state}

          {pending_call, pending_calls} ->
            new_state =
              state
              |> Map.put(:pending_rpc_calls, pending_calls)
              |> Map.put(:pending_rpc_monitors, pending_monitors)

            {:ok, pending_call, new_state}
        end
    end
  end

  defp pending_rpc_monitor?(state, monitor_ref) do
    Map.has_key?(Map.get(state, :pending_rpc_monitors, %{}), monitor_ref)
  end

  defp maybe_reply_pending_call(:none, _reply), do: :ok
  defp maybe_reply_pending_call(from, reply), do: GenServer.reply(from, reply)

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

        :none ->
          state.stats
      end

    %{state | stats: stats}
  end

  # Shutdown detection helpers
  # These eliminate race conditions between port exit messages and shutdown signals

  @doc false
  # Peek into mailbox to detect if a shutdown signal is pending but not yet processed.
  # This handles the race where port exit arrives before the EXIT message is processed.
  # Only called on rare port-exit path, not on hot request paths.
  defp shutdown_pending_in_mailbox? do
    case Process.info(self(), :messages) do
      {:messages, msgs} ->
        Enum.any?(msgs, fn
          {:EXIT, _from, reason} -> Shutdown.shutdown_reason?(reason)
          _ -> false
        end)

      _ ->
        false
    end
  end

  @doc false
  # Check if the pool is still alive - if not, we're in system shutdown
  defp pool_alive?(pool_name) do
    pool_pid =
      case pool_name do
        name when is_atom(name) -> Process.whereis(name)
        _ -> pool_name
      end

    case pool_pid do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # Check if the Erlang runtime is in the process of stopping.
  # This catches cases where Application.stop has been called but other
  # shutdown signals haven't propagated yet.
  defp system_stopping? do
    case :init.get_status() do
      {:stopping, _} -> true
      {_, :stopping} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
