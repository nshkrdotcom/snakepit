defmodule Snakepit.Pool.CapacitySchedulingTest do
  use Snakepit.TestCase, async: true

  alias Snakepit.Pool
  alias Snakepit.Pool.State

  setup do
    if Process.whereis(Snakepit.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Snakepit.TaskSupervisor})
    end

    cache =
      :ets.new(:capacity_scheduling_test_cache, [
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

    base_pool_state = %State{
      name: :capacity_pool,
      size: 1,
      workers: ["worker_a"],
      available: MapSet.new(["worker_a"]),
      worker_loads: %{},
      worker_capacities: %{"worker_a" => 2},
      capacity_strategy: :pool,
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: stats,
      initialized: true,
      startup_timeout: 1_000,
      queue_timeout: 10,
      max_queue_size: 100,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_config: %{worker_profile: :thread, threads_per_worker: 2, capacity_strategy: :pool}
    }

    state = %Pool{
      pools: %{capacity_pool: base_pool_state},
      affinity_cache: cache,
      default_pool: :capacity_pool
    }

    on_exit(fn ->
      case :ets.info(cache) do
        :undefined -> :ok
        _ -> :ets.delete(cache)
      end
    end)

    %{state: state}
  end

  test "checkout increments load until capacity reached", %{state: state} do
    {:reply, {:ok, worker_id}, state} =
      Pool.handle_call({:checkout_worker, nil}, {self(), make_ref()}, state)

    assert worker_id == "worker_a"
    assert state.pools.capacity_pool.worker_loads["worker_a"] == 1
    assert MapSet.member?(state.pools.capacity_pool.available, "worker_a")

    {:reply, {:ok, worker_id}, state} =
      Pool.handle_call({:checkout_worker, nil}, {self(), make_ref()}, state)

    assert worker_id == "worker_a"
    assert state.pools.capacity_pool.worker_loads["worker_a"] == 2
    refute MapSet.member?(state.pools.capacity_pool.available, "worker_a")
  end

  test "session affinity prefers the cached worker when capacity remains", %{state: state} do
    session_id = "session_prefers_worker"
    expires_at = System.monotonic_time(:second) + 60
    :ets.insert(state.affinity_cache, {session_id, "worker_a", expires_at})

    pool_state = %{
      state.pools.capacity_pool
      | workers: ["worker_a", "worker_b"],
        available: MapSet.new(["worker_a", "worker_b"]),
        worker_loads: %{"worker_a" => 1},
        worker_capacities: %{"worker_a" => 2, "worker_b" => 1}
    }

    state = %{state | pools: %{capacity_pool: pool_state}}

    {:reply, {:ok, worker_id}, state} =
      Pool.handle_call({:checkout_worker, session_id}, {self(), make_ref()}, state)

    assert worker_id == "worker_a"
    assert state.pools.capacity_pool.worker_loads["worker_a"] == 2
  end

  test "session affinity falls back when preferred worker is at capacity", %{state: state} do
    session_id = "session_fallback_worker"
    expires_at = System.monotonic_time(:second) + 60
    :ets.insert(state.affinity_cache, {session_id, "worker_a", expires_at})

    pool_state = %{
      state.pools.capacity_pool
      | workers: ["worker_a", "worker_b"],
        available: MapSet.new(["worker_b"]),
        worker_loads: %{"worker_a" => 2},
        worker_capacities: %{"worker_a" => 2, "worker_b" => 1}
    }

    state = %{state | pools: %{capacity_pool: pool_state}}

    {:reply, {:ok, worker_id}, state} =
      Pool.handle_call({:checkout_worker, session_id}, {self(), make_ref()}, state)

    assert worker_id == "worker_b"
    assert state.pools.capacity_pool.worker_loads["worker_b"] == 1
  end
end
