defmodule Snakepit.Pool.StreamCheckoutTest do
  use Snakepit.TestCase, async: true

  alias Snakepit.Pool
  alias Snakepit.Pool.State

  setup do
    if Process.whereis(Snakepit.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Snakepit.TaskSupervisor})
    end

    cache =
      :ets.new(:stream_checkout_cache, [
        :set,
        :public,
        {:read_concurrency, true}
      ])

    stats = %{
      requests: 0,
      queued: 0,
      errors: 0,
      queue_timeouts: 0,
      pool_saturated: 0
    }

    pool_a = %State{
      name: :pool_a,
      size: 1,
      workers: ["worker_a"],
      available: MapSet.new(["worker_a"]),
      worker_loads: %{},
      worker_capacities: %{"worker_a" => 1},
      capacity_strategy: :pool,
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: stats,
      initialized: true,
      startup_timeout: 1_000,
      queue_timeout: 60_000,
      max_queue_size: 100,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_config: %{worker_profile: :process, capacity_strategy: :pool, affinity: :hint}
    }

    pool_b = %State{
      name: :pool_b,
      size: 1,
      workers: ["worker_b"],
      available: MapSet.new(["worker_b"]),
      worker_loads: %{},
      worker_capacities: %{"worker_b" => 1},
      capacity_strategy: :pool,
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: stats,
      initialized: true,
      startup_timeout: 1_000,
      queue_timeout: 60_000,
      max_queue_size: 100,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_config: %{worker_profile: :process, capacity_strategy: :pool, affinity: :hint}
    }

    state = %Pool{
      pools: %{pool_a: pool_a, pool_b: pool_b},
      affinity_cache: cache,
      default_pool: :pool_a
    }

    on_exit(fn ->
      case :ets.info(cache) do
        :undefined -> :ok
        _ -> :ets.delete(cache)
      end
    end)

    %{state: state}
  end

  test "streaming checkout honors pool_name in opts", %{state: state} do
    session_id = "stream_session_pool_b"
    expires_at = System.monotonic_time(:second) + 60
    :ets.insert(state.affinity_cache, {session_id, "worker_b", expires_at})

    opts = [pool_name: :pool_b, call_type: :execute_stream]

    {:reply, {:ok, worker_id}, new_state} =
      Pool.handle_call({:checkout_worker, session_id, opts}, {self(), make_ref()}, state)

    assert worker_id == "worker_b"
    assert new_state.pools.pool_b.worker_loads["worker_b"] == 1
    assert new_state.pools.pool_a.worker_loads == %{}
  end

  test "execute resolves string pool_name to configured pool", %{state: state} do
    from = {self(), make_ref()}

    pool_b = %{state.pools.pool_b | available: MapSet.new()}
    pools = Map.put(state.pools, :pool_b, pool_b)
    state = %{state | pools: pools}

    {:noreply, new_state} =
      Pool.handle_call({:execute, "ping", %{}, [pool_name: "pool_b"]}, from, state)

    assert :queue.len(new_state.pools.pool_b.request_queue) == 1
    assert :queue.len(new_state.pools.pool_a.request_queue) == 0
  end
end
