defmodule Snakepit.Pool.QueueManagementTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool
  alias Snakepit.Pool.PoolState

  setup do
    cache =
      :ets.new(:queue_management_test_cache, [
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

    pool_state = %PoolState{
      name: :queue_pool,
      size: 1,
      workers: [],
      available: MapSet.new(),
      busy: %{},
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: stats,
      initialized: true,
      startup_timeout: 1_000,
      queue_timeout: 10,
      max_queue_size: 100,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_config: %{}
    }

    state = %Pool{
      pools: %{queue_pool: pool_state},
      affinity_cache: cache,
      default_pool: :queue_pool
    }

    on_exit(fn ->
      case :ets.info(cache) do
        :undefined -> :ok
        _ -> :ets.delete(cache)
      end
    end)

    %{state: state}
  end

  test "cancelled request map remains bounded under heavy churn", %{state: original_state} do
    iterations = 2_000

    final_state =
      Enum.reduce(1..iterations, original_state, fn _, state ->
        from = {self(), make_ref()}
        tag = elem(from, 1)

        {:noreply, new_state} = Pool.handle_info({:queue_timeout, :queue_pool, from}, state)
        assert_receive {^tag, {:error, :queue_timeout}}
        new_state
      end)

    cancelled = final_state.pools.queue_pool.cancelled_requests
    assert map_size(cancelled) <= 1_024
  end

  test "queue timeout removes request from the in-memory queue", %{state: state} do
    from = {self(), make_ref()}
    tag = elem(from, 1)
    request = {from, "command", %{}, %{}, System.monotonic_time()}

    pool_state = %{
      state.pools.queue_pool
      | request_queue: :queue.in(request, state.pools.queue_pool.request_queue)
    }

    state = %{state | pools: %{queue_pool: pool_state}}

    {:noreply, new_state} = Pool.handle_info({:queue_timeout, :queue_pool, from}, state)
    assert_receive {^tag, {:error, :queue_timeout}}

    assert :queue.is_empty(new_state.pools.queue_pool.request_queue)
    assert Map.has_key?(new_state.pools.queue_pool.cancelled_requests, from)
  end

  test "stale cancelled entries are pruned on worker checkin", %{state: state} do
    old_timestamp = System.monotonic_time(:millisecond) - 500
    stale_from = {self(), make_ref()}

    pool_state = %{
      state.pools.queue_pool
      | cancelled_requests: %{stale_from => old_timestamp}
    }

    state = %{state | pools: %{queue_pool: pool_state}}

    {:noreply, new_state} = Pool.handle_cast({:checkin_worker, :queue_pool, "worker_1"}, state)

    refute Map.has_key?(new_state.pools.queue_pool.cancelled_requests, stale_from)
  end

  test "cancelled queue entries are dropped on checkin", %{state: state} do
    queued_from = {self(), make_ref()}
    request = {queued_from, "command", %{}, %{}, System.monotonic_time()}

    pool_state = %{
      state.pools.queue_pool
      | request_queue: :queue.in(request, state.pools.queue_pool.request_queue),
        cancelled_requests: %{queued_from => System.monotonic_time(:millisecond)}
    }

    state = %{state | pools: %{queue_pool: pool_state}}

    {:noreply, new_state} = Pool.handle_cast({:checkin_worker, :queue_pool, "worker_1"}, state)

    assert :queue.is_empty(new_state.pools.queue_pool.request_queue)
    refute Map.has_key?(new_state.pools.queue_pool.cancelled_requests, queued_from)

    # Flush the synthetic cast emitted during the cancellation skip
    receive do
      {:"$gen_cast", {:checkin_worker, :queue_pool, "worker_1"}} -> :ok
      {:"$gen_cast", {:checkin_worker, _pool, _worker}} -> :ok
    after
      0 -> :ok
    end
  end

  test "enqueue compacts stale cancelled requests before applying queue limits", %{state: state} do
    now_ms = System.monotonic_time(:millisecond)

    {from_a, from_b} = {{self(), make_ref()}, {self(), make_ref()}}
    request_a = {from_a, "command_a", %{}, %{}, System.monotonic_time()}
    request_b = {from_b, "command_b", %{}, %{}, System.monotonic_time()}

    queue = :queue.from_list([request_a, request_b])

    cancelled = %{
      from_a => now_ms,
      from_b => now_ms
    }

    pool_state = %{
      state.pools.queue_pool
      | request_queue: queue,
        cancelled_requests: cancelled,
        max_queue_size: 2
    }

    state = %{state | pools: %{queue_pool: pool_state}}

    from_new = {self(), make_ref()}
    {:noreply, new_state} = Pool.handle_call({:execute, "command_c", %{}, %{}}, from_new, state)

    queue_after = new_state.pools.queue_pool.request_queue |> :queue.to_list()
    assert length(queue_after) == 1
    assert Enum.map(queue_after, fn {queued_from, _, _, _, _} -> queued_from end) == [from_new]
    assert new_state.pools.queue_pool.cancelled_requests == %{}

    # Drain any queue timeout messages scheduled during the enqueue
    receive do
      {:queue_timeout, _pool, ^from_new} -> :ok
      {:queue_timeout, ^from_new} -> :ok
    after
      20 -> :ok
    end
  end
end
