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
  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Error
  alias Snakepit.GRPC.Client
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Logger.Redaction
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Telemetry.Correlation
  alias Snakepit.Telemetry.GrpcStream
  alias Snakepit.Worker.LifecycleManager
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
    pool_name = Keyword.get(opts, :pool_name, Snakepit.Pool)

    pool_identifier = resolve_pool_identifier(opts, pool_name)

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
  def execute(worker, command, args, timeout \\ 30_000)

  def execute(worker_id, command, args, timeout) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:execute, command, args, timeout}, timeout + 1_000)

      {:error, _} ->
        {:error,
         Error.worker_error("Worker not found", %{worker_id: worker_id, command: command})}
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
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(
          pid,
          {:execute_stream, command, args, callback_fn, timeout},
          timeout + 1_000
        )

      {:error, _} ->
        {:error,
         Error.worker_error("Worker not found", %{worker_id: worker_id, command: command})}
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

  defp resolve_pool_identifier(opts, pool_name) do
    case Keyword.get(opts, :pool_identifier) do
      identifier when is_atom(identifier) ->
        identifier

      identifier when is_binary(identifier) ->
        string_to_existing_atom_safe(identifier)

      _ ->
        infer_pool_identifier(pool_name)
    end
  end

  defp string_to_existing_atom_safe(identifier) do
    String.to_existing_atom(identifier)
  rescue
    ArgumentError -> nil
  end

  defp infer_pool_identifier(pool_name) when is_atom(pool_name), do: pool_name

  defp infer_pool_identifier(pool_name) when is_pid(pool_name) do
    case Process.info(pool_name, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp infer_pool_identifier(_), do: nil

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

  defp ensure_registry_metadata(metadata, pool_name, pool_identifier) do
    metadata
    |> Map.put(:worker_module, __MODULE__)
    |> Map.put(:pool_name, pool_name)
    |> maybe_put_pool_identifier(pool_identifier)
  end

  defp maybe_attach_registry_metadata(worker_id, metadata) when is_binary(worker_id) do
    case PoolRegistry.put_metadata(worker_id, metadata) do
      :ok ->
        :ok

      {:error, :not_registered} ->
        SLog.debug("Pool.Registry missing entry for #{worker_id} while attaching metadata")
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_attach_registry_metadata(_worker_id, _metadata), do: :ok

  defp normalize_worker_config(config, pool_name, adapter_module, pool_identifier) do
    config
    |> Map.put(:worker_module, __MODULE__)
    |> Map.put_new(:adapter_module, adapter_module)
    |> Map.put(:pool_name, pool_name)
    |> maybe_put_pool_identifier(pool_identifier)
  end

  defp current_process_memory_bytes do
    case Process.info(self(), :memory) do
      {:memory, bytes} when is_integer(bytes) and bytes >= 0 -> bytes
      _ -> 0
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # CRITICAL: Trap exits so terminate/2 is called on shutdown
    # Without this, the GenServer is brutally killed and Python processes are orphaned!
    Process.flag(:trap_exit, true)

    adapter = Keyword.fetch!(opts, :adapter)
    worker_id = Keyword.fetch!(opts, :id)
    pool_name = Keyword.get(opts, :pool_name, Snakepit.Pool)
    pool_identifier = Keyword.get(opts, :pool_identifier)

    metadata =
      opts
      |> Keyword.get(:registry_metadata, %{})
      |> ensure_registry_metadata(pool_name, pool_identifier)

    maybe_attach_registry_metadata(worker_id, metadata)

    case ProcessRegistry.reserve_worker(worker_id) do
      :ok ->
        init_worker(opts, adapter, worker_id, pool_name, pool_identifier)

      {:error, reason} ->
        SLog.error("Failed to reserve worker slot for #{worker_id}: #{inspect(reason)}")
        {:stop, {:reservation_failed, reason}}
    end
  end

  defp init_worker(opts, adapter, worker_id, pool_name, pool_identifier) do
    SLog.debug("Reserved worker slot for #{worker_id}")

    session_id = generate_session_id()
    elixir_address = build_elixir_address()
    port = adapter.get_port()

    worker_config =
      opts
      |> Keyword.get(:worker_config, %{})
      |> normalize_worker_config(pool_name, adapter, pool_identifier)

    heartbeat_config =
      worker_config
      |> get_worker_config_section(:heartbeat)
      |> normalize_heartbeat_config()

    spawn_config =
      build_spawn_config(adapter, worker_config, heartbeat_config, port, elixir_address)

    server_port = spawn_grpc_server(spawn_config)
    process_pid = extract_and_log_pid(server_port, port)

    register_worker_pid(worker_id, process_pid)

    state_params = %{
      worker_id: worker_id,
      pool_name: pool_name,
      adapter: adapter,
      port: port,
      server_port: server_port,
      process_pid: process_pid,
      session_id: session_id,
      worker_config: worker_config,
      heartbeat_config: heartbeat_config
    }

    state = build_initial_state(state_params)

    {:ok, state, {:continue, :connect_and_wait}}
  end

  defp generate_session_id do
    "session_#{:erlang.unique_integer([:positive, :monotonic])}_#{:erlang.system_time(:microsecond)}"
  end

  defp build_elixir_address do
    elixir_grpc_host = Application.get_env(:snakepit, :grpc_host, "localhost")
    elixir_grpc_port = Application.get_env(:snakepit, :grpc_port, 50_051)
    "#{elixir_grpc_host}:#{elixir_grpc_port}"
  end

  defp build_spawn_config(adapter, worker_config, heartbeat_config, port, elixir_address) do
    executable = adapter.executable_path()
    adapter_args = resolve_adapter_args(adapter, worker_config)
    adapter_env = worker_config |> Map.get(:adapter_env, []) |> merge_with_default_adapter_env()
    heartbeat_env_json = encode_heartbeat_env(heartbeat_config)
    script_path = determine_script_path(adapter, adapter_args)
    args = build_spawn_args(adapter_args, port, elixir_address)

    SLog.info("Starting gRPC server: #{executable} #{script_path || ""} #{Enum.join(args, " ")}")

    %{
      executable: executable,
      script_path: script_path,
      args: args,
      adapter_env: adapter_env,
      heartbeat_env_json: heartbeat_env_json
    }
  end

  defp resolve_adapter_args(adapter, worker_config) do
    worker_adapter_args = Map.get(worker_config, :adapter_args, [])

    if worker_adapter_args == [] do
      adapter.script_args() || []
    else
      worker_adapter_args
    end
  end

  defp determine_script_path(adapter, adapter_args) do
    if Enum.any?(adapter_args, fn arg ->
         is_binary(arg) and String.contains?(arg, "--max-workers")
       end) do
      app_dir = Application.app_dir(:snakepit)
      Path.join([app_dir, "priv", "python", "grpc_server_threaded.py"])
    else
      adapter.script_path()
    end
  end

  defp build_spawn_args(adapter_args, port, elixir_address) do
    adapter_args
    |> maybe_add_arg("--port", to_string(port))
    |> maybe_add_arg("--elixir-address", elixir_address)
    |> add_run_id_arg()
  end

  defp maybe_add_arg(args, flag, value) do
    if Enum.any?(args, &String.contains?(&1, flag)) do
      args
    else
      args ++ [flag, value]
    end
  end

  defp add_run_id_arg(args) do
    run_id = ProcessRegistry.get_beam_run_id()
    args ++ ["--snakepit-run-id", run_id]
  end

  defp spawn_grpc_server(%{
         executable: executable,
         script_path: script_path,
         args: args,
         adapter_env: adapter_env,
         heartbeat_env_json: heartbeat_env_json
       }) do
    {spawn_args, port_opts} = build_port_config(script_path, args)
    port_opts = apply_env_to_port_opts(port_opts, adapter_env, heartbeat_env_json)

    server_port = Port.open({:spawn_executable, executable}, [{:args, spawn_args} | port_opts])
    Port.monitor(server_port)
    server_port
  end

  defp build_port_config(script_path, args) do
    case script_path do
      path when is_binary(path) and byte_size(path) > 0 ->
        {
          [path | args],
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:cd, Path.dirname(path)}]
        }

      _ ->
        {args, [:binary, :exit_status, :use_stdio, :stderr_to_stdout]}
    end
  end

  defp apply_env_to_port_opts(port_opts, adapter_env, heartbeat_env_json) do
    env_entries = adapter_env |> maybe_put_heartbeat_env(heartbeat_env_json)

    if env_entries != [] do
      env_tuples = Enum.map(env_entries, &to_env_tuple/1)
      port_opts ++ [{:env, env_tuples}]
    else
      port_opts
    end
  end

  defp extract_and_log_pid(server_port, port) do
    case Port.info(server_port, :os_pid) do
      {:os_pid, pid} ->
        SLog.info("Started gRPC server process, will listen on TCP port #{port}")
        pid

      error ->
        SLog.error("Failed to get gRPC server process PID: #{inspect(error)}")
        nil
    end
  end

  defp register_worker_pid(_worker_id, nil), do: :ok

  defp register_worker_pid(worker_id, process_pid) do
    case ProcessRegistry.activate_worker(worker_id, self(), process_pid, "grpc_worker") do
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

  defp build_initial_state(%{
         worker_id: worker_id,
         pool_name: pool_name,
         adapter: adapter,
         port: port,
         server_port: server_port,
         process_pid: process_pid,
         session_id: session_id,
         worker_config: worker_config,
         heartbeat_config: heartbeat_config
       }) do
    %{
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
      connection: nil,
      health_check_ref: nil,
      stats: %{
        requests: 0,
        errors: 0,
        start_time: System.monotonic_time()
      }
    }
  end

  defp resolve_pool_pid(pool_name) when is_atom(pool_name), do: Process.whereis(pool_name)
  defp resolve_pool_pid(pool_name), do: pool_name

  defp verify_pool_alive(nil, worker_id), do: {:error, {:pool_dead, worker_id}}

  defp verify_pool_alive(pool_pid, worker_id) do
    if Process.alive?(pool_pid) do
      :ok
    else
      {:error, {:pool_dead, worker_id}}
    end
  end

  defp complete_worker_initialization(state, connection, actual_port) do
    health_ref = schedule_health_check()

    LifecycleManager.track_worker(state.pool_name, state.id, self(), state.worker_config)

    SLog.info("✅ gRPC worker #{state.id} initialization complete and acknowledged.")

    maybe_initialize_session(connection, state.session_id)
    register_telemetry_stream(connection, state)
    emit_worker_spawned_telemetry(state, actual_port)

    new_state =
      state
      |> Map.put(:connection, connection)
      |> Map.put(:port, actual_port)
      |> Map.put(:health_check_ref, health_ref)
      |> maybe_start_heartbeat_monitor()

    {:noreply, new_state}
  end

  defp emit_worker_spawned_telemetry(state, actual_port) do
    start_time = Map.get(state.stats, :start_time, System.monotonic_time())

    :telemetry.execute(
      [:snakepit, :pool, :worker, :spawned],
      %{
        duration: System.monotonic_time() - start_time,
        system_time: System.system_time()
      },
      %{
        node: node(),
        pool_name: state.pool_name,
        worker_id: state.id,
        worker_pid: self(),
        python_port: actual_port,
        python_pid: state.process_pid,
        mode: :process
      }
    )
  end

  @impl true
  def handle_continue(:connect_and_wait, state) do
    with {:ok, actual_port} <- wait_for_server_ready(state.server_port, 30_000),
         {:ok, connection} <-
           wrap_grpc_connection_result(state.adapter.init_grpc_connection(actual_port)),
         pool_pid <- resolve_pool_pid(state.pool_name),
         :ok <- verify_pool_alive(pool_pid, state.id),
         :ok <- notify_pool_ready(pool_pid, state.id) do
      complete_worker_initialization(state, connection, actual_port)
    else
      {:error, {:exit_status, status}} when status in [0, 137, 143] ->
        SLog.debug("gRPC server exited during startup with status #{status} (shutdown)")
        {:stop, {:grpc_server_failed, {:exit_status, status}}, state}

      {:error, {:pool_dead, _}} ->
        SLog.debug(
          "Worker #{state.id} finished starting but Pool is shut down. Stopping gracefully."
        )

        {:stop, :normal, state}

      {:error, {:pool_handshake_failed, reason}} ->
        SLog.debug("Pool handshake failed for worker #{state.id}: #{inspect(reason)}")
        {:stop, :shutdown, state}

      {:error, {:grpc_connection_failed, reason}} ->
        SLog.error("Failed to connect to gRPC server: #{reason}")
        {:stop, {:grpc_connection_failed, reason}, state}

      {:error, reason} ->
        SLog.error("Failed to start gRPC server: #{inspect(reason)}")
        {:stop, {:grpc_server_failed, reason}, state}
    end
  end

  defp wrap_grpc_connection_result({:ok, connection}), do: {:ok, connection}

  defp wrap_grpc_connection_result({:error, reason}),
    do: {:error, {:grpc_connection_failed, reason}}

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

    args_with_corr = ensure_correlation(args)

    result =
      state.adapter.grpc_execute_stream(
        state.connection,
        state.session_id,
        command,
        args_with_corr,
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

    emit_worker_terminated_telemetry(state, reason)
    cleanup_heartbeat(state, reason)
    kill_python_process(state.process_pid, reason)
    cleanup_resources(state)

    :ok
  end

  defp emit_worker_terminated_telemetry(state, reason) do
    start_time = Map.get(state.stats, :start_time, 0)
    total_commands = Map.get(state.stats, :requests, 0)

    :telemetry.execute(
      [:snakepit, :pool, :worker, :terminated],
      %{
        lifetime: System.monotonic_time() - start_time,
        total_commands: total_commands
      },
      %{
        node: node(),
        pool_name: state.pool_name,
        worker_id: state.id,
        worker_pid: self(),
        reason: reason,
        planned: reason in [:shutdown, :normal]
      }
    )
  end

  defp cleanup_heartbeat(state, reason) do
    maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
    maybe_notify_test_pid(state.heartbeat_config, {:heartbeat_monitor_stopped, state.id, reason})
  end

  defp kill_python_process(nil, _reason), do: :ok

  defp kill_python_process(process_pid, reason) when reason in [:shutdown, :normal] do
    SLog.debug("Starting graceful shutdown of external gRPC process PID: #{process_pid}...")

    case Snakepit.ProcessKiller.kill_with_escalation(process_pid, @graceful_shutdown_timeout) do
      :ok ->
        SLog.debug("✅ gRPC server PID #{process_pid} terminated gracefully")

      {:error, kill_reason} ->
        SLog.warning("Failed to gracefully kill #{process_pid}: #{inspect(kill_reason)}")
    end
  end

  defp kill_python_process(process_pid, reason) do
    SLog.warning(
      "Non-graceful termination (#{inspect(reason)}), immediately killing PID #{process_pid}"
    )

    case Snakepit.ProcessKiller.kill_process(process_pid, :sigkill) do
      :ok ->
        SLog.debug("✅ Immediately killed gRPC server PID #{process_pid}")

      {:error, kill_reason} ->
        SLog.warning("Failed to kill #{process_pid}: #{inspect(kill_reason)}")
    end
  end

  defp cleanup_resources(state) do
    disconnect_connection(state.connection)
    cancel_health_check_timer(state.health_check_ref)
    close_server_port(state.server_port)
    GrpcStream.unregister_worker(state.id)
    ProcessRegistry.unregister_worker(state.id)
  end

  defp cancel_health_check_timer(nil), do: :ok

  defp cancel_health_check_timer(health_check_ref) do
    Process.cancel_timer(health_check_ref)
  end

  defp close_server_port(nil), do: :ok

  defp close_server_port(server_port) do
    safe_close_port(server_port)
  end

  defp notify_pool_ready(nil, worker_id),
    do:
      {:error,
       {:pool_handshake_failed, Error.pool_error("Pool not found", %{worker_id: worker_id})}}

  defp notify_pool_ready(pool_pid, worker_id) when is_pid(pool_pid) do
    GenServer.call(pool_pid, {:worker_ready, worker_id}, 30_000)
  catch
    :exit, {:noproc, _} ->
      {:error,
       {:pool_handshake_failed,
        Error.pool_error("Pool not found", %{worker_id: worker_id, pool_pid: pool_pid})}}

    :exit, {:shutdown, _} = reason ->
      {:error, {:pool_handshake_failed, reason}}

    :exit, {:killed, _} = reason ->
      {:error, {:pool_handshake_failed, reason}}

    :exit, {:timeout, _} = reason ->
      {:error, {:pool_handshake_failed, reason}}

    :exit, reason ->
      {:error, {:pool_handshake_failed, reason}}
  else
    :ok ->
      :ok

    other ->
      {:error, {:pool_handshake_failed, {:unexpected_reply, other}}}
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
        _ = Client.initialize_session(channel, session_id, %{})
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
        SLog.debug("Registered telemetry stream for worker #{state.id}")
        :ok
      rescue
        exception ->
          SLog.warning(
            "Failed to register telemetry stream for worker #{state.id}: #{inspect(exception)}"
          )

          :error
      catch
        :exit, reason ->
          SLog.warning(
            "Telemetry stream registration exited for worker #{state.id}: #{inspect(reason)}"
          )

          :error
      end
    else
      SLog.debug("No channel available for telemetry stream registration")
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
    GRPC.Stub.disconnect(channel)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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

  defp merge_with_default_adapter_env(env) do
    existing = normalize_adapter_env_entries(env)
    defaults = default_adapter_env()

    existing_keys =
      existing
      |> Enum.map(fn {key, _} -> String.downcase(key) end)
      |> MapSet.new()

    defaults
    |> Enum.reject(fn {key, _value} -> MapSet.member?(existing_keys, String.downcase(key)) end)
    |> Kernel.++(existing)
  end

  defp default_adapter_env do
    priv_python =
      :code.priv_dir(:snakepit)
      |> to_string()
      |> Path.join("python")

    repo_priv_python =
      Path.join(File.cwd!(), "priv/python")

    path_sep = path_separator()

    pythonpath =
      [System.get_env("PYTHONPATH"), priv_python, repo_priv_python]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(path_sep)

    interpreter =
      Application.get_env(:snakepit, :python_executable) ||
        System.get_env("SNAKEPIT_PYTHON") ||
        GRPCPython.executable_path()

    []
    |> maybe_cons("PYTHONPATH", pythonpath)
    |> maybe_cons("SNAKEPIT_PYTHON", interpreter)
  end

  defp maybe_cons(acc, _key, value) when value in [nil, ""], do: acc
  defp maybe_cons(acc, key, value), do: [{key, value} | acc]

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
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
    case Client.health(state.connection.channel, inspect(self())) do
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
