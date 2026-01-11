defmodule Snakepit.Pool.AffinityStrictTest do
  use Snakepit.TestCase, async: true

  alias Snakepit.Pool
  alias Snakepit.Pool.State

  setup do
    if Process.whereis(Snakepit.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Snakepit.TaskSupervisor})
    end

    cache =
      :ets.new(:affinity_strict_test_cache, [
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
      name: :strict_pool,
      size: 2,
      workers: ["worker_a", "worker_b"],
      available: MapSet.new(),
      worker_loads: %{},
      worker_capacities: %{},
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
      pool_config: %{worker_profile: :process, capacity_strategy: :pool}
    }

    state = %Pool{
      pools: %{strict_pool: base_pool_state},
      affinity_cache: cache,
      default_pool: :strict_pool
    }

    on_exit(fn ->
      case :ets.info(cache) do
        :undefined -> :ok
        _ -> :ets.delete(cache)
      end
    end)

    %{state: state}
  end

  test "strict queue enqueues when preferred worker is busy", %{state: state} do
    session_id = "strict_queue_session"
    expires_at = System.monotonic_time(:second) + 60
    :ets.insert(state.affinity_cache, {session_id, "worker_a", expires_at})

    pool_state = %{
      state.pools.strict_pool
      | available: MapSet.new(["worker_b"]),
        worker_loads: %{"worker_a" => 1},
        worker_capacities: %{"worker_a" => 1, "worker_b" => 1},
        pool_config: %{
          worker_profile: :process,
          capacity_strategy: :pool,
          affinity: :strict_queue
        }
    }

    state = %{state | pools: %{strict_pool: pool_state}}

    from = {self(), make_ref()}

    {:noreply, new_state} =
      Pool.handle_call({:execute, "ping", %{}, [session_id: session_id]}, from, state)

    assert :queue.len(new_state.pools.strict_pool.request_queue) == 1
    assert new_state.pools.strict_pool.worker_loads == pool_state.worker_loads

    [request] = :queue.to_list(new_state.pools.strict_pool.request_queue)
    assert match?({^from, "ping", %{}, _, _, _, "worker_a"}, request)
  end

  test "strict fail-fast returns worker_busy when preferred worker is busy", %{state: state} do
    session_id = "strict_failfast_session"
    expires_at = System.monotonic_time(:second) + 60
    :ets.insert(state.affinity_cache, {session_id, "worker_a", expires_at})

    pool_state = %{
      state.pools.strict_pool
      | available: MapSet.new(["worker_b"]),
        worker_loads: %{"worker_a" => 1},
        worker_capacities: %{"worker_a" => 1, "worker_b" => 1},
        pool_config: %{
          worker_profile: :process,
          capacity_strategy: :pool,
          affinity: :strict_fail_fast
        }
    }

    state = %{state | pools: %{strict_pool: pool_state}}

    from = {self(), make_ref()}

    {:reply, {:error, :worker_busy}, new_state} =
      Pool.handle_call({:execute, "ping", %{}, [session_id: session_id]}, from, state)

    assert :queue.is_empty(new_state.pools.strict_pool.request_queue)
    assert new_state.pools.strict_pool.worker_loads == pool_state.worker_loads
  end
end
