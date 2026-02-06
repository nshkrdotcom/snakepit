defmodule Snakepit.GRPCWorker.Bootstrap do
  @moduledoc false

  require Logger
  alias Snakepit.Defaults
  alias Snakepit.Error
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Worker.Configuration
  alias Snakepit.Worker.ProcessManager

  @log_category :grpc

  # Base heartbeat defaults - actual values are retrieved via Defaults module
  # to allow runtime configuration. These are the compile-time fallbacks.
  @base_heartbeat_defaults_template %{
    enabled: true,
    ping_fun: nil,
    test_pid: nil,
    dependent: true
  }

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

  def connect_and_wait(state, complete_fun) when is_function(complete_fun, 3) do
    with {:ok, actual_port} <-
           ProcessManager.wait_for_server_ready(
             state.server_port,
             state.ready_file,
             Defaults.grpc_server_ready_timeout()
           ),
         state <- maybe_update_process_group_after_ready(state),
         {:ok, connection} <-
           wrap_grpc_connection_result(state.adapter.init_grpc_connection(actual_port)),
         pool_pid <- resolve_pool_pid(state.pool_name),
         :ok <- verify_pool_alive(pool_pid, state.id),
         :ok <- notify_pool_ready(pool_pid, state.id) do
      complete_fun.(state, connection, actual_port)
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

  defp maybe_update_process_group_after_ready(%{process_group?: true} = state), do: state

  defp maybe_update_process_group_after_ready(%{process_pid: process_pid} = state)
       when is_integer(process_pid) do
    if process_group_spawn_enabled?() do
      case resolve_process_group_with_retry(process_pid, 250) do
        {:ok, pgid} when pgid == process_pid ->
          case ProcessRegistry.update_process_group(state.id, process_pid, pgid) do
            :ok ->
              %{state | pgid: pgid, process_group?: true}

            {:error, _reason} ->
              # Registry update failure is non-fatal; worker still tracks state locally.
              %{state | pgid: pgid, process_group?: true}
          end

        _ ->
          # If we still can't prove pgid == pid after readiness, keep safety rails
          # and kill by PID only. This can leave multiprocessing grandchildren alive.
          SLog.warning(
            @log_category,
            "Process group requested but not observed after readiness; group kill disabled for worker #{state.id}",
            process_pid: process_pid
          )

          state
      end
    else
      state
    end
  end

  defp maybe_update_process_group_after_ready(state), do: state

  defp process_group_spawn_enabled? do
    Application.get_env(:snakepit, :process_group_kill, true) and
      Snakepit.ProcessKiller.process_group_supported?()
  end

  defp resolve_process_group_with_retry(process_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    resolve_process_group_with_retry_loop(process_pid, deadline, 1)
  end

  defp resolve_process_group_with_retry_loop(process_pid, deadline, backoff_ms) do
    case Snakepit.ProcessKiller.get_process_group_id(process_pid) do
      {:ok, pgid} when pgid == process_pid ->
        {:ok, pgid}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          delay = min(backoff_ms, 50)

          receive do
          after
            delay -> :ok
          end

          resolve_process_group_with_retry_loop(process_pid, deadline, backoff_ms * 2)
        end
    end
  end

  def normalize_heartbeat_config(config) when is_map(config) do
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

  def normalize_heartbeat_config(_config), do: default_heartbeat_config()

  defp init_worker(opts, adapter, worker_id, pool_name, pool_identifier) do
    SLog.debug(@log_category, "Reserved worker slot for #{worker_id}")

    session_id = generate_session_id()
    Logger.metadata(session_id: session_id)

    elixir_address =
      opts
      |> Keyword.get(:elixir_address)
      |> case do
        nil ->
          opts
          |> Keyword.get(:worker_config, %{})
          |> Map.get(:elixir_address)

        value ->
          value
      end
      |> case do
        nil -> build_elixir_address()
        value -> value
      end

    port = adapter.get_port()

    worker_config =
      opts
      |> Keyword.get(:worker_config, %{})
      |> Configuration.normalize_worker_config(
        Snakepit.GRPCWorker,
        pool_name,
        adapter,
        pool_identifier
      )

    heartbeat_config =
      worker_config
      |> get_worker_config_section(:heartbeat)
      |> normalize_heartbeat_config()

    spawn_config =
      Configuration.build_spawn_config(
        adapter,
        worker_config,
        heartbeat_config,
        port,
        elixir_address,
        worker_id
      )

    server_port = ProcessManager.spawn_grpc_server(spawn_config)
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
    case Snakepit.GRPC.Listener.address() do
      address when is_binary(address) ->
        address

      _ ->
        raise "gRPC listener address not available; ensure listener has started"
    end
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
      },
      rpc_request_queue: :queue.new(),
      pending_rpc_calls: %{},
      pending_rpc_monitors: %{}
    }
  end

  defp ensure_registry_metadata(metadata, pool_name, pool_identifier) do
    metadata
    |> Map.put(:worker_module, Snakepit.GRPCWorker)
    |> Map.put(:pool_name, pool_name)
    |> maybe_put_pool_identifier(pool_identifier)
  end

  defp maybe_put_pool_identifier(metadata, nil), do: metadata

  defp maybe_put_pool_identifier(metadata, identifier),
    do: Map.put(metadata, :pool_identifier, identifier)

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

  defp wrap_grpc_connection_result({:ok, connection}), do: {:ok, connection}

  defp wrap_grpc_connection_result({:error, reason}),
    do: {:error, {:grpc_connection_failed, reason}}

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

  defp base_heartbeat_defaults do
    Map.merge(@base_heartbeat_defaults_template, %{
      ping_interval_ms: Defaults.heartbeat_ping_interval_ms(),
      timeout_ms: Defaults.heartbeat_timeout_ms(),
      max_missed_heartbeats: Defaults.heartbeat_max_missed(),
      initial_delay_ms: Defaults.heartbeat_initial_delay_ms()
    })
  end

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
end
