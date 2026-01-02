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
  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Defaults
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
          shutting_down: boolean()
        }

  # Base heartbeat defaults - actual values are retrieved via Defaults module
  # to allow runtime configuration. These are the compile-time fallbacks.
  @base_heartbeat_defaults_template %{
    enabled: true,
    ping_fun: nil,
    test_pid: nil,
    dependent: true
  }

  defp base_heartbeat_defaults do
    Map.merge(@base_heartbeat_defaults_template, %{
      ping_interval_ms: Defaults.heartbeat_ping_interval_ms(),
      timeout_ms: Defaults.heartbeat_timeout_ms(),
      max_missed_heartbeats: Defaults.heartbeat_max_missed(),
      initial_delay_ms: Defaults.heartbeat_initial_delay_ms()
    })
  end

  @heartbeat_known_keys [
    :enabled,
    :ping_interval_ms,
    :timeout_ms,
    :max_missed_heartbeats,
    :ping_fun,
    :test_pid,
    :initial_delay_ms,
    :dependent
  ]
  @heartbeat_known_key_strings Enum.map(@heartbeat_known_keys, &Atom.to_string/1)
  @log_category :grpc

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
  def execute(worker, command, args, timeout \\ nil)

  def execute(worker, command, args, nil) do
    execute(worker, command, args, Defaults.grpc_worker_execute_timeout())
  end

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
  def execute_stream(worker, command, args, callback_fn, timeout \\ nil)

  def execute_stream(worker, command, args, callback_fn, nil) do
    execute_stream(worker, command, args, callback_fn, Defaults.grpc_worker_stream_timeout())
  end

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
  def execute_in_session(worker, session_id, command, args, timeout \\ nil)

  def execute_in_session(worker, session_id, command, args, nil) do
    execute_in_session(worker, session_id, command, args, Defaults.grpc_worker_execute_timeout())
  end

  def execute_in_session(worker, session_id, command, args, timeout) do
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
        SLog.debug(
          @log_category,
          "Pool.Registry missing entry for #{worker_id} while attaching metadata"
        )

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

    Logger.metadata(worker_id: worker_id, pool_name: pool_name, adapter: adapter)

    metadata =
      opts
      |> Keyword.get(:registry_metadata, %{})
      |> ensure_registry_metadata(pool_name, pool_identifier)

    maybe_attach_registry_metadata(worker_id, metadata)

    case ProcessRegistry.reserve_worker(worker_id) do
      :ok ->
        init_worker(opts, adapter, worker_id, pool_name, pool_identifier)

      {:error, reason} ->
        SLog.error(
          @log_category,
          "Failed to reserve worker slot for #{worker_id}: #{inspect(reason)}"
        )

        {:stop, {:reservation_failed, reason}}
    end
  end

  defp init_worker(opts, adapter, worker_id, pool_name, pool_identifier) do
    SLog.debug(@log_category, "Reserved worker slot for #{worker_id}")

    session_id = generate_session_id()
    Logger.metadata(session_id: session_id)
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
      build_spawn_config(
        adapter,
        worker_config,
        heartbeat_config,
        port,
        elixir_address,
        worker_id
      )

    server_port = spawn_grpc_server(spawn_config)
    process_pid = extract_and_log_pid(server_port, port)
    {pgid, process_group?} = resolve_process_group(process_pid, spawn_config)

    register_worker_pid(worker_id, process_pid, pgid, process_group?)

    state_params = %{
      worker_id: worker_id,
      pool_name: pool_name,
      adapter: adapter,
      port: port,
      server_port: server_port,
      process_pid: process_pid,
      pgid: pgid,
      process_group?: process_group?,
      session_id: session_id,
      worker_config: worker_config,
      heartbeat_config: heartbeat_config,
      ready_file: spawn_config.ready_file
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

  defp build_spawn_config(
         adapter,
         worker_config,
         heartbeat_config,
         port,
         elixir_address,
         worker_id
       ) do
    python_executable = adapter.executable_path()
    adapter_args = resolve_adapter_args(adapter, worker_config)
    adapter_env = worker_config |> Map.get(:adapter_env, []) |> merge_with_default_adapter_env()
    heartbeat_env_json = encode_heartbeat_env(heartbeat_config)
    ready_file = build_ready_file(worker_id)
    script_path = determine_script_path(adapter, adapter_args)
    args = build_spawn_args(adapter_args, port, elixir_address)

    SLog.info(
      @log_category,
      "Starting gRPC server: #{python_executable} #{script_path || ""} #{Enum.join(args, " ")}"
    )

    %{
      executable: python_executable,
      script_path: script_path,
      args: args,
      process_group?: process_group_spawn?(),
      adapter_env: adapter_env,
      heartbeat_env_json: heartbeat_env_json,
      ready_file: ready_file
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

  defp build_ready_file(worker_id) do
    base_dir = System.tmp_dir() || File.cwd!()

    safe_worker_id =
      worker_id
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")

    unique = :erlang.unique_integer([:positive, :monotonic])
    Path.join(base_dir, "snakepit_ready_#{safe_worker_id}_#{unique}")
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
         heartbeat_env_json: heartbeat_env_json,
         ready_file: ready_file
       }) do
    {spawn_args, port_opts} = build_port_config(script_path, args)
    port_opts = apply_env_to_port_opts(port_opts, adapter_env, heartbeat_env_json, ready_file)

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

  defp process_group_spawn? do
    Application.get_env(:snakepit, :process_group_kill, true) and
      Snakepit.ProcessKiller.process_group_supported?()
  end

  defp resolve_process_group(process_pid, %{process_group?: true})
       when is_integer(process_pid) do
    with {:ok, pgid} <- Snakepit.ProcessKiller.get_process_group_id(process_pid),
         true <- pgid == process_pid do
      {pgid, true}
    else
      _ -> {nil, false}
    end
  end

  defp resolve_process_group(_process_pid, _spawn_config), do: {nil, false}

  defp apply_env_to_port_opts(port_opts, adapter_env, heartbeat_env_json, ready_file) do
    env_entries =
      adapter_env
      |> maybe_put_heartbeat_env(heartbeat_env_json)
      |> maybe_put_ready_file_env(ready_file)
      |> maybe_put_log_level_env()

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
        SLog.info(@log_category, "Started gRPC server process, will listen on TCP port #{port}")
        pid

      error ->
        SLog.error(@log_category, "Failed to get gRPC server process PID: #{inspect(error)}")
        nil
    end
  end

  defp register_worker_pid(_worker_id, nil, _pgid, _process_group?), do: :ok

  defp register_worker_pid(worker_id, process_pid, pgid, process_group?) do
    case ProcessRegistry.activate_worker(worker_id, self(), process_pid, "grpc_worker",
           pgid: pgid,
           process_group?: process_group?
         ) do
      :ok ->
        SLog.debug(
          @log_category,
          "Registered Python PID #{process_pid} for worker #{worker_id} in ProcessRegistry"
        )

      {:error, reason} ->
        SLog.error(
          @log_category,
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
         pgid: pgid,
         process_group?: process_group?,
         session_id: session_id,
         worker_config: worker_config,
         heartbeat_config: heartbeat_config,
         ready_file: ready_file
       }) do
    %{
      id: worker_id,
      pool_name: pool_name,
      adapter: adapter,
      port: port,
      server_port: server_port,
      process_pid: process_pid,
      pgid: pgid,
      process_group?: process_group?,
      session_id: session_id,
      requested_port: port,
      worker_config: worker_config,
      heartbeat_config: heartbeat_config,
      ready_file: ready_file,
      heartbeat_monitor: nil,
      connection: nil,
      health_check_ref: nil,
      python_output_buffer: "",
      # Track whether we initiated shutdown (to distinguish expected vs unexpected exits)
      shutting_down: false,
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

    SLog.info(
      @log_category,
      "✅ gRPC worker #{state.id} initialization complete and acknowledged."
    )

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
    with {:ok, actual_port} <-
           wait_for_server_ready(
             state.server_port,
             state.ready_file,
             Defaults.grpc_server_ready_timeout()
           ),
         {:ok, connection} <-
           wrap_grpc_connection_result(state.adapter.init_grpc_connection(actual_port)),
         pool_pid <- resolve_pool_pid(state.pool_name),
         :ok <- verify_pool_alive(pool_pid, state.id),
         :ok <- notify_pool_ready(pool_pid, state.id) do
      complete_worker_initialization(state, connection, actual_port)
    else
      {:error, :shutdown} ->
        SLog.debug(@log_category, "gRPC server exited during startup (shutdown)")
        {:stop, :shutdown, state}

      {:error, {:exit_status, status}} when status in [137] ->
        SLog.error(@log_category, "gRPC server exited during startup with status #{status}")
        {:stop, {:grpc_server_failed, {:exit_status, status}}, state}

      {:error, {:pool_dead, _}} ->
        SLog.debug(
          @log_category,
          "Worker #{state.id} finished starting but Pool is shut down. Stopping gracefully."
        )

        {:stop, :normal, state}

      {:error, {:pool_handshake_failed, reason}} ->
        SLog.debug(
          @log_category,
          "Pool handshake failed for worker #{state.id}: #{inspect(reason)}"
        )

        {:stop, :shutdown, state}

      {:error, {:grpc_connection_failed, reason}} ->
        SLog.error(@log_category, "Failed to connect to gRPC server: #{reason}")
        {:stop, {:grpc_connection_failed, reason}, state}

      {:error, reason} ->
        SLog.error(@log_category, "Failed to start gRPC server: #{inspect(reason)}")
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
    SLog.debug(
      @log_category,
      "[GRPCWorker] execute_stream #{command} with args #{Redaction.describe(args)}"
    )

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

    SLog.debug(@log_category, "[GRPCWorker] execute_stream result: #{Redaction.describe(result)}")

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
        SLog.warning(@log_category, "Health check failed: #{reason}")
        # Could implement reconnection logic here
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :port, port, reason}, %{server_port: port} = state) do
    # Use same shutdown detection as exit_status handler to avoid race conditions.
    # :DOWN can arrive before or instead of exit_status on some platforms.
    effective_shutting_down? =
      state.shutting_down or
        shutdown_pending_in_mailbox?() or
        not pool_alive?(state.pool_name) or
        Snakepit.Shutdown.in_progress?()

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
    buffer = append_startup_output(state.python_output_buffer, output)

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
    remaining_output = drain_port_buffer(port, 200)

    last_output =
      state.python_output_buffer
      |> append_startup_output(remaining_output)
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
        Snakepit.Shutdown.in_progress?()

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

  # Graceful shutdown timeout for Python process termination.
  # Must be >= Python's shutdown envelope: server.stop(2s) + wait_for_termination(3s) = 5s
  # We use 6s as default to provide margin. Configurable via :graceful_shutdown_timeout_ms.
  @default_graceful_shutdown_timeout 6000

  # Margin added to graceful_shutdown_timeout for supervisor shutdown.
  # This gives the worker time to complete its terminate/2 callback.
  @shutdown_margin 2000

  defp graceful_shutdown_timeout do
    Application.get_env(
      :snakepit,
      :graceful_shutdown_timeout_ms,
      @default_graceful_shutdown_timeout
    )
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
    graceful_shutdown_timeout() + @shutdown_margin
  end

  @impl true
  def terminate(reason, state) do
    SLog.debug(
      @log_category,
      "GRPCWorker.terminate/2 called for #{state.id}, reason: #{inspect(reason)}, PID: #{state.process_pid}"
    )

    SLog.debug(@log_category, "gRPC worker #{state.id} terminating: #{inspect(reason)}")

    emit_worker_terminated_telemetry(state, reason)
    cleanup_heartbeat(state, reason)
    kill_python_process(state, reason)
    cleanup_ready_file(state.ready_file)
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
        planned: shutdown_reason?(reason) or reason == :normal
      }
    )
  end

  defp cleanup_heartbeat(state, reason) do
    maybe_stop_heartbeat_monitor(state.heartbeat_monitor)
    maybe_notify_test_pid(state.heartbeat_config, {:heartbeat_monitor_stopped, state.id, reason})
  end

  # Group all kill_python_process clauses together
  defp kill_python_process(%{process_pid: nil}, _reason), do: :ok

  defp kill_python_process(state, reason) when reason == :normal do
    do_graceful_kill(state)
  end

  defp kill_python_process(state, :shutdown) do
    do_graceful_kill(state)
  end

  defp kill_python_process(state, {:shutdown, _}) do
    do_graceful_kill(state)
  end

  defp kill_python_process(state, reason) do
    SLog.warning(
      @log_category,
      "Non-graceful termination (#{inspect(reason)}), immediately killing PID #{state.process_pid}"
    )

    result =
      if use_process_group_kill?(state) do
        Snakepit.ProcessKiller.kill_process_group(state.pgid, :sigkill)
      else
        Snakepit.ProcessKiller.kill_process(state.process_pid, :sigkill)
      end

    case result do
      :ok ->
        SLog.debug(@log_category, "✅ Immediately killed gRPC server PID #{state.process_pid}")

      {:error, kill_reason} ->
        SLog.warning(
          @log_category,
          "Failed to kill #{state.process_pid}: #{inspect(kill_reason)}"
        )
    end
  end

  defp do_graceful_kill(state) do
    SLog.debug(
      @log_category,
      "Starting graceful shutdown of external gRPC process PID: #{state.process_pid}..."
    )

    result =
      if use_process_group_kill?(state) do
        Snakepit.ProcessKiller.kill_process_group_with_escalation(
          state.pgid,
          graceful_shutdown_timeout()
        )
      else
        Snakepit.ProcessKiller.kill_with_escalation(
          state.process_pid,
          graceful_shutdown_timeout()
        )
      end

    case result do
      :ok ->
        SLog.debug(@log_category, "✅ gRPC server PID #{state.process_pid} terminated gracefully")

      {:error, kill_reason} ->
        SLog.warning(
          @log_category,
          "Failed to gracefully kill #{state.process_pid}: #{inspect(kill_reason)}"
        )
    end
  end

  defp use_process_group_kill?(%{process_group?: true, pgid: pgid})
       when is_integer(pgid) do
    Application.get_env(:snakepit, :process_group_kill, true)
  end

  defp use_process_group_kill?(_state), do: false

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
    GenServer.call(pool_pid, {:worker_ready, worker_id}, Defaults.worker_ready_timeout())
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
            SLog.error(
              @log_category,
              "Failed to start heartbeat monitor for #{state.id}: #{inspect(reason)}"
            )

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
      base_heartbeat_defaults(),
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

    snakebridge_priv_python =
      case :code.priv_dir(:snakebridge) do
        {:error, _} -> nil
        priv_dir -> Path.join([to_string(priv_dir), "python"])
      end

    path_sep = path_separator()

    pythonpath =
      [System.get_env("PYTHONPATH"), priv_python, repo_priv_python, snakebridge_priv_python]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(path_sep)

    interpreter =
      Application.get_env(:snakepit, :python_executable) ||
        System.get_env("SNAKEPIT_PYTHON") ||
        GRPCPython.executable_path()

    process_group_env =
      if Application.get_env(:snakepit, :process_group_kill, true) and
           Snakepit.ProcessKiller.process_group_supported?() do
        [{"SNAKEPIT_PROCESS_GROUP", "1"}]
      else
        []
      end

    base =
      []
      |> maybe_cons("PYTHONPATH", pythonpath)
      |> maybe_cons("SNAKEPIT_PYTHON", interpreter)

    extra_env =
      Snakepit.PythonRuntime.config()
      |> Map.get(:extra_env, %{})
      |> normalize_adapter_env_entries()

    base ++ process_group_env ++ extra_env ++ Snakepit.PythonRuntime.runtime_env()
  end

  defp maybe_cons(acc, _key, value) when value in [nil, ""], do: acc
  defp maybe_cons(acc, key, value), do: [{key, value} | acc]

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  defp elixir_to_python_level(:debug), do: "debug"
  defp elixir_to_python_level(:info), do: "info"
  defp elixir_to_python_level(:warning), do: "warning"
  defp elixir_to_python_level(:error), do: "error"
  defp elixir_to_python_level(:none), do: "none"
  defp elixir_to_python_level(_), do: "error"

  defp maybe_put_heartbeat_env(entries, nil), do: entries

  defp maybe_put_heartbeat_env(entries, json),
    do: maybe_put_env(entries, "SNAKEPIT_HEARTBEAT_CONFIG", json)

  defp maybe_put_ready_file_env(entries, ready_file),
    do: maybe_put_env(entries, "SNAKEPIT_READY_FILE", ready_file)

  defp maybe_put_log_level_env(entries) do
    level = Application.get_env(:snakepit, :log_level, :error)
    maybe_put_env(entries, "SNAKEPIT_LOG_LEVEL", elixir_to_python_level(level))
  end

  defp maybe_put_env(entries, _key, value) when value in [nil, ""], do: entries

  defp maybe_put_env(entries, key, value) do
    filtered =
      Enum.reject(entries, fn {existing_key, _value} ->
        String.downcase(existing_key) == String.downcase(key)
      end)

    [{key, value} | filtered]
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

  defp wait_for_server_ready(port, ready_file, timeout, output_buffer \\ "") do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer)
  end

  defp wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer) do
    case read_ready_file(ready_file) do
      {:ok, actual_port} ->
        cleanup_ready_file(ready_file)
        {:ok, actual_port}

      {:error, reason} ->
        cleanup_ready_file(ready_file)
        log_startup_output(output_buffer)
        SLog.error(@log_category, "Failed to read readiness file: #{inspect(reason)}")
        {:error, {:ready_file, reason}}

      :not_ready ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining == 0 do
          cleanup_ready_file(ready_file)
          log_startup_output(output_buffer)

          SLog.error(
            @log_category,
            "Timeout waiting for Python gRPC server to start after #{timeout}ms"
          )

          {:error, :timeout}
        else
          receive do
            {^port, {:data, data}} ->
              output = to_string(data)
              output_buffer = append_startup_output(output_buffer, output)

              if String.trim(output) != "" do
                SLog.debug(
                  @log_category,
                  "Python server output during startup: #{String.trim(output)}"
                )
              end

              wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer)

            {^port, {:exit_status, status}} ->
              cleanup_ready_file(ready_file)

              case status do
                0 ->
                  SLog.debug(
                    @log_category,
                    "Python gRPC server process exited with status 0 during startup (shutdown)"
                  )

                  {:error, :shutdown}

                143 ->
                  SLog.debug(
                    @log_category,
                    "Python gRPC server process exited with status 143 during startup (shutdown)"
                  )

                  {:error, :shutdown}

                _ ->
                  log_startup_output(output_buffer)

                  SLog.error(
                    @log_category,
                    "Python gRPC server process exited with status #{status} during startup"
                  )

                  {:error, {:exit_status, status}}
              end

            {:DOWN, _ref, :port, ^port, reason} ->
              cleanup_ready_file(ready_file)
              log_startup_output(output_buffer)

              SLog.error(
                @log_category,
                "Python gRPC server port died during startup: #{inspect(reason)}"
              )

              {:error, {:port_died, reason}}
          after
            min(remaining, 50) ->
              wait_for_server_ready_loop(port, ready_file, deadline, timeout, output_buffer)
          end
        end
    end
  end

  defp read_ready_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {port, _} ->
            {:ok, port}

          :error ->
            # Empty or invalid content - file may still be mid-write (atomic rename race)
            # Treat as not ready and keep polling
            :not_ready
        end

      {:error, :enoent} ->
        :not_ready

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_ready_file(path) do
    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  defp append_startup_output(buffer, output) do
    max_bytes = 4096
    buffer = buffer <> output

    if byte_size(buffer) > max_bytes do
      String.slice(buffer, byte_size(buffer) - max_bytes, max_bytes)
    else
      buffer
    end
  end

  defp log_startup_output(buffer) do
    trimmed = String.trim(buffer)

    if trimmed != "" do
      SLog.error(@log_category, "Python server output during startup:\n#{trimmed}")
    end
  end

  defp log_python_output? do
    Application.get_env(:snakepit, :log_python_output, false)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, Defaults.grpc_worker_health_check_interval())
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

  # Shutdown detection helpers
  # These eliminate race conditions between port exit messages and shutdown signals

  @doc false
  # Matches both :shutdown and {:shutdown, term} which supervisors use
  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _}), do: true
  defp shutdown_reason?(_), do: false

  @doc false
  # Peek into mailbox to detect if a shutdown signal is pending but not yet processed.
  # This handles the race where port exit arrives before the EXIT message is processed.
  # Only called on rare port-exit path, not on hot request paths.
  defp shutdown_pending_in_mailbox? do
    case Process.info(self(), :messages) do
      {:messages, msgs} ->
        Enum.any?(msgs, fn
          {:EXIT, _from, reason} -> shutdown_reason?(reason)
          _ -> false
        end)

      _ ->
        false
    end
  end

  @doc false
  # Check if the pool is still alive - if not, we're in system shutdown
  defp pool_alive?(pool_name) do
    case resolve_pool_pid(pool_name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
