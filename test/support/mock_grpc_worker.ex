defmodule Snakepit.Test.MockGRPCWorker do
  @moduledoc """
  Mock gRPC worker for testing that bypasses actual process spawning.
  """

  use GenServer
  use Supertester.TestableGenServer
  require Logger

  alias Snakepit.Defaults
  alias Snakepit.Pool.ProcessRegistry

  # Module interface expected by Pool
  def execute(worker_id, command, args, timeout_or_opts) do
    {timeout, opts} = normalize_execute_opts(timeout_or_opts)

    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:execute, command, args, timeout, opts}, timeout)

      [] ->
        {:error, :worker_not_found}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    worker_id = Keyword.fetch!(opts, :id)
    port = Keyword.get(opts, :port, adapter.get_port())
    pool_name = Keyword.get(opts, :pool_name, Snakepit.Pool)

    # Store test PID for sending messages
    Process.put(:test_pid, Keyword.get(opts, :test_pid, self()))

    session_id = Keyword.get(opts, :session_id, "mock_session")

    state = %{
      id: worker_id,
      adapter: adapter,
      port: port,
      pool_name: pool_name,
      connection: nil,
      session_id: session_id,
      stats: %{requests: 0, errors: 0}
    }

    # Send ready message to test process
    test_pid = Process.get(:test_pid)
    send(test_pid, {:grpc_ready, port})

    # Register worker in pool registry with module info
    Registry.register(Snakepit.Pool.Registry, worker_id, %{worker_module: __MODULE__})

    # Simulate successful connection
    case adapter.init_grpc_connection(port) do
      {:ok, connection} ->
        # Register with ProcessRegistry for consistency with GRPCWorker
        # Use nil for process_pid since mock doesn't spawn external process
        ProcessRegistry.reserve_worker(worker_id)

        ProcessRegistry.activate_worker(
          worker_id,
          self(),
          nil,
          "mock_grpc_worker"
        )

        :ok = maybe_notify_pool_ready(pool_name, worker_id)

        {:ok, %{state | connection: connection}}

      {:error, reason} ->
        {:stop, {:grpc_server_failed, reason}}
    end
  end

  @impl true
  def handle_call({:execute, command, args, timeout}, from, state) do
    handle_call({:execute, command, args, timeout, []}, from, state)
  end

  def handle_call({:execute, command, args, timeout, opts}, _from, state) do
    case state.adapter.grpc_execute(
           state.connection,
           state.session_id,
           command,
           args,
           timeout,
           opts
         ) do
      {:ok, result} ->
        new_state = update_in(state.stats.requests, &(&1 + 1))
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        new_state = update_in(state.stats.errors, &(&1 + 1))
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:get_memory_usage, _from, state) do
    {:reply, {:ok, current_process_memory_bytes()}, state}
  end

  # Note: __supertester_sync__ handler is automatically injected by TestableGenServer

  @impl true
  def handle_info(:health_check, state) do
    # Mock health check - always healthy
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MockGRPCWorker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Unregister from pool registry
    Registry.unregister(Snakepit.Pool.Registry, state.id)

    # Unregister from ProcessRegistry for consistency with GRPCWorker
    ProcessRegistry.unregister_worker(state.id)

    :ok
  end

  defp current_process_memory_bytes do
    case Process.info(self(), :memory) do
      {:memory, bytes} when is_integer(bytes) and bytes >= 0 -> bytes
      _ -> 0
    end
  end

  defp normalize_execute_opts(opts) when is_list(opts) do
    {Keyword.get(opts, :timeout, Defaults.grpc_worker_execute_timeout()), opts}
  end

  defp normalize_execute_opts(timeout) when is_integer(timeout) or timeout == :infinity do
    {timeout, []}
  end

  defp maybe_notify_pool_ready(pool_name, worker_id) do
    pool_pid =
      cond do
        is_pid(pool_name) -> pool_name
        true -> Process.whereis(pool_name)
      end

    case pool_pid do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          case Process.info(pid, :registered_name) do
            {:registered_name, []} -> :ok
            {:registered_name, nil} -> :ok
            _ -> GenServer.cast(pid, {:worker_ready, worker_id})
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
