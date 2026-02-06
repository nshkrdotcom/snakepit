defmodule Snakepit.GRPC.Listener do
  @moduledoc false

  use GenServer

  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.GRPC.EndpointRegistry
  alias Snakepit.Logger, as: SLog

  @listener_key {__MODULE__, :listener_info}
  @default_start_fun &__MODULE__.start_endpoint/3
  @log_category :grpc

  @type listener_info :: %{
          pid: pid() | nil,
          host: String.t(),
          bind_host: String.t(),
          port: non_neg_integer(),
          mode: Config.grpc_listener_mode()
        }

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    init_opts = Keyword.take(opts, [:config, :start_fun, :adapter_opts])

    if name do
      GenServer.start_link(__MODULE__, init_opts, name: name)
    else
      GenServer.start_link(__MODULE__, init_opts)
    end
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec listener_info() :: listener_info() | nil
  def listener_info do
    :persistent_term.get(listener_key(current_endpoint()), nil)
  end

  @spec host() :: String.t() | nil
  def host do
    case listener_info() do
      %{host: host} -> host
      _ -> nil
    end
  end

  @spec port() :: non_neg_integer() | nil
  def port do
    case listener_info() do
      %{port: port} -> port
      _ -> nil
    end
  end

  @spec mode() :: Config.grpc_listener_mode() | nil
  def mode do
    case listener_info() do
      %{mode: mode} -> mode
      _ -> nil
    end
  end

  @spec address() :: String.t() | nil
  def address do
    case listener_info() do
      %{host: host, port: port} when is_binary(host) and is_integer(port) ->
        "#{host}:#{port}"

      _ ->
        nil
    end
  end

  @spec clear_listener_info() :: :ok
  def clear_listener_info do
    :persistent_term.erase(listener_key(current_endpoint()))
    :ok
  end

  @spec await_ready(pos_integer()) :: {:ok, listener_info()} | {:error, :timeout}
  def await_ready(timeout \\ Config.grpc_listener_ready_timeout_ms()) do
    endpoint_module = current_endpoint()
    deadline = System.monotonic_time(:millisecond) + timeout
    await_ready_loop(deadline, endpoint_module)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.get(opts, :config) || Config.grpc_listener_config!()
    start_fun = Keyword.get(opts, :start_fun, @default_start_fun)
    adapter_opts = Keyword.get(opts, :adapter_opts, build_adapter_opts(config))
    endpoint_module = Keyword.get(opts, :endpoint_module, EndpointRegistry.endpoint_module())

    state = %{
      config: config,
      start_fun: start_fun,
      adapter_opts: adapter_opts,
      endpoint_module: endpoint_module,
      server_pid: nil,
      manage_server?: start_fun == @default_start_fun,
      published?: false
    }

    {:ok, state, {:continue, :start_listener}}
  end

  @impl true
  def handle_continue(:start_listener, state) do
    case start_listener(state) do
      {:ok, %{pid: pid} = info} ->
        Process.link(pid)
        publish_listener(info, state.endpoint_module)

        manage_server? = Map.get(info, :manage_server?, state.manage_server?)
        {:noreply, %{state | server_pid: pid, manage_server?: manage_server?, published?: true}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    maybe_stop_endpoint(state)
    maybe_clear_listener_info(state)
    :ok
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{server_pid: pid} = state) do
    clear_published_listener_info(state)
    stop_reason = normalize_listener_exit_reason(reason)
    {:stop, stop_reason, %{state | server_pid: nil, published?: false}}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp await_ready_loop(deadline, endpoint_module) do
    case :persistent_term.get(listener_key(endpoint_module), nil) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          receive do
          after
            Config.grpc_listener_port_check_interval_ms() ->
              await_ready_loop(deadline, endpoint_module)
          end
        end

      info ->
        cond do
          is_pid(info[:pid]) and Process.alive?(info[:pid]) ->
            {:ok, info}

          listener_running?(endpoint_module) ->
            {:ok, info}

          true ->
            clear_listener_info(endpoint_module)

            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :timeout}
            else
              receive do
              after
                Config.grpc_listener_port_check_interval_ms() ->
                  await_ready_loop(deadline, endpoint_module)
              end
            end
        end
    end
  end

  defp publish_listener(
         %{host: host, bind_host: bind_host, port: port, mode: mode} = info,
         endpoint_module
       ) do
    payload = %{
      host: host,
      bind_host: bind_host,
      port: port,
      mode: mode
    }

    payload =
      case Map.get(info, :pid) do
        pid when is_pid(pid) -> Map.put(payload, :pid, pid)
        _ -> payload
      end

    :persistent_term.put(listener_key(endpoint_module), payload)
  end

  defp start_listener(%{config: %{mode: :internal} = config} = state) do
    start_with_port(config, 0, state)
  end

  defp start_listener(%{config: %{mode: :external, port: port} = config} = state) do
    start_with_port(config, port, state)
  end

  defp start_listener(%{config: %{mode: :external_pool} = config} = state) do
    ports = port_pool(config)

    Enum.reduce_while(ports, {:error, :no_available_ports}, fn port, _acc ->
      case start_with_port(config, port, state) do
        {:ok, _info} = ok ->
          {:halt, ok}

        {:error, reason} ->
          if port_in_use?(reason) do
            SLog.debug(@log_category, "gRPC port #{port} already in use; trying next")
            {:cont, {:error, reason}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp start_with_port(config, port, state, attempts_left \\ nil)

  defp start_with_port(config, port, state, nil) do
    start_with_port(config, port, state, Config.grpc_listener_reuse_attempts())
  end

  defp start_with_port(
         config,
         port,
         %{
           start_fun: start_fun,
           adapter_opts: adapter_opts,
           manage_server?: manage_server?,
           endpoint_module: endpoint_module
         } = state,
         attempts_left
       )
       when attempts_left > 0 do
    opts = [adapter_opts: adapter_opts]

    case start_fun.(endpoint_module, port, opts) do
      {:ok, pid, actual_port} ->
        {:ok, build_info(pid, actual_port, config, manage_server?)}

      {:error, {:already_started, pid}} ->
        handle_existing_listener(config, pid, port, state, attempts_left)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp port_pool(%{base_port: base_port, pool_size: pool_size})
       when is_integer(base_port) and is_integer(pool_size) do
    base_port..(base_port + pool_size - 1)
  end

  defp port_pool(_config), do: []

  defp port_in_use?({:error, :eaddrinuse}), do: true
  defp port_in_use?({:error, reason}), do: port_in_use?(reason)
  defp port_in_use?(:eaddrinuse), do: true

  defp port_in_use?({:shutdown, {:failed_to_start_child, _child, reason}}),
    do: port_in_use?(reason)

  defp port_in_use?({:shutdown, {_, _, {{_, {:error, :eaddrinuse}}, _}}}), do: true
  defp port_in_use?({:shutdown, {_, _, reason}}), do: port_in_use?(reason)
  defp port_in_use?(_reason), do: false

  defp build_adapter_opts(%{bind_host: bind_host}) do
    base_opts = [
      num_acceptors: Defaults.grpc_num_acceptors(),
      max_connections: Defaults.grpc_max_connections(),
      socket_opts: [backlog: Defaults.grpc_socket_backlog()]
    ]

    case parse_ip(bind_host) do
      {:ok, ip_tuple} -> Keyword.put(base_opts, :ip, ip_tuple)
      :error -> base_opts
    end
  end

  defp parse_ip(nil), do: :error

  defp parse_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_), do: :error

  defp reuse_existing_listener(config, pid, timeout_ms, endpoint_module) do
    if process_available?(pid) do
      case port_from_listener_info(endpoint_module) do
        {:ok, port} ->
          case validate_existing_port(config, port) do
            :ok ->
              {:ok, build_info(pid, port, config, false)}

            {:error, reason} ->
              {:error, reason}
          end

        :error ->
          case wait_for_existing_port(pid, timeout_ms, endpoint_module) do
            {:ok, port} ->
              case validate_existing_port(config, port) do
                :ok ->
                  {:ok, build_info(pid, port, config, false)}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:error, :listener_stale}
    end
  end

  defp existing_listener_port(endpoint_module) do
    listener_name = listener_name(endpoint_module)

    try do
      port = :ranch.get_port(listener_name)

      if is_integer(port) and port > 0 do
        {:ok, port}
      else
        :error
      end
    rescue
      _ -> :error
    end
  end

  defp listener_name(endpoint_module) do
    inspect(endpoint_module)
  end

  defp maybe_stop_endpoint(%{
         manage_server?: true,
         server_pid: pid,
         endpoint_module: endpoint_module
       })
       when is_pid(pid) do
    try do
      GRPC.Server.stop_endpoint(endpoint_module)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    _ = await_listener_stopped(Config.grpc_listener_ready_timeout_ms(), endpoint_module)
  end

  defp maybe_stop_endpoint(_state), do: :ok

  defp maybe_clear_listener_info(%{manage_server?: true, published?: true} = state) do
    clear_listener_info(state.endpoint_module)
  end

  defp maybe_clear_listener_info(_state), do: :ok

  defp clear_published_listener_info(%{published?: true, endpoint_module: endpoint_module}) do
    clear_listener_info(endpoint_module)
  end

  defp clear_published_listener_info(_state), do: :ok

  defp normalize_listener_exit_reason(:shutdown), do: :shutdown
  defp normalize_listener_exit_reason({:shutdown, _} = reason), do: reason
  defp normalize_listener_exit_reason(reason), do: {:listener_exit, reason}

  defp await_listener_stopped(timeout_ms, endpoint_module)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_listener_stopped_loop(deadline, endpoint_module)
  end

  defp await_listener_stopped_loop(deadline, endpoint_module) do
    if listener_running?(endpoint_module) do
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        receive do
        after
          Config.grpc_listener_port_check_interval_ms() ->
            await_listener_stopped_loop(deadline, endpoint_module)
        end
      end
    else
      :ok
    end
  end

  defp listener_running?(endpoint_module) do
    listener_name = listener_name(endpoint_module)

    try do
      _ = :ranch.info(listener_name)
      true
    rescue
      _ -> false
    end
  end

  defp wait_for_existing_port(pid, timeout_ms, endpoint_module)
       when is_pid(pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    ref = Process.monitor(pid)
    result = wait_for_existing_port(pid, ref, deadline, endpoint_module)
    Process.demonitor(ref, [:flush])
    result
  end

  defp wait_for_existing_port(pid, ref, deadline, endpoint_module) do
    case port_from_listener_info(endpoint_module) do
      {:ok, port} ->
        if process_available?(pid), do: {:ok, port}, else: {:error, :listener_stale}

      :error ->
        case existing_listener_port(endpoint_module) do
          {:ok, port} ->
            if process_available?(pid), do: {:ok, port}, else: {:error, :listener_stale}

          :error ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :listener_port_unavailable}
            else
              receive do
                {:DOWN, ^ref, :process, ^pid, _reason} ->
                  {:error, :listener_stale}
              after
                Config.grpc_listener_port_check_interval_ms() ->
                  wait_for_existing_port(pid, ref, deadline, endpoint_module)
              end
            end
        end
    end
  end

  defp process_available?(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    available? =
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> false
      after
        0 -> true
      end

    Process.demonitor(ref, [:flush])
    available?
  end

  defp handle_existing_listener(config, pid, port, state, attempts_left) do
    timeout_ms =
      if attempts_left > 1 do
        Config.grpc_listener_reuse_wait_timeout_ms()
      else
        Config.grpc_listener_ready_timeout_ms()
      end

    case reuse_existing_listener(config, pid, timeout_ms, state.endpoint_module) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason}
      when attempts_left > 1 and reason in [:listener_stale, :listener_port_unavailable] ->
        _ = await_listener_stopped(Config.grpc_listener_ready_timeout_ms(), state.endpoint_module)

        SLog.debug(
          @log_category,
          "gRPC listener reuse failed (#{inspect(reason)}); retrying start"
        )

        receive do
        after
          Config.grpc_listener_reuse_retry_delay_ms() ->
            start_with_port(config, port, state, attempts_left - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp port_from_listener_info(endpoint_module) do
    case :persistent_term.get(listener_key(endpoint_module), nil) do
      %{port: port} when is_integer(port) and port > 0 -> {:ok, port}
      _ -> :error
    end
  end

  defp validate_existing_port(%{mode: :external, port: expected}, actual) do
    if expected == actual do
      :ok
    else
      {:error, {:grpc_listener_port_mismatch, expected, actual}}
    end
  end

  defp validate_existing_port(
         %{mode: :external_pool, base_port: base_port, pool_size: pool_size},
         actual
       )
       when is_integer(base_port) and is_integer(pool_size) do
    if actual in base_port..(base_port + pool_size - 1) do
      :ok
    else
      {:error, {:grpc_listener_port_mismatch, base_port, actual}}
    end
  end

  defp validate_existing_port(_config, _actual), do: :ok

  defp build_info(pid, port, config, manage_server?) do
    %{
      pid: pid,
      port: port,
      host: config.host,
      bind_host: config.bind_host,
      mode: config.mode,
      manage_server?: manage_server?
    }
  end

  defp current_endpoint do
    EndpointRegistry.endpoint_module()
  end

  defp listener_key(endpoint_module) do
    {@listener_key, endpoint_module}
  end

  defp clear_listener_info(endpoint_module) do
    :persistent_term.erase(listener_key(endpoint_module))
    :ok
  end

  @doc false
  @spec start_endpoint(atom(), non_neg_integer(), Keyword.t()) ::
          {:ok, pid(), non_neg_integer()} | {:error, term()}
  def start_endpoint(endpoint, port, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, GRPC.Server.Adapters.Cowboy)
    servers = endpoint.__meta__(:servers) |> GRPC.Server.servers_to_map()
    adapter.start(endpoint, servers, port, opts)
  end
end
