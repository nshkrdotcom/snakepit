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

defmodule Snakepit.Pool.QueueSaturationRuntimeTest do
  @moduledoc false
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import ExUnit.CaptureLog
  require Logger

  alias Snakepit.TestAdapters.QueueProbeAdapter
  alias MapSet

  setup do
    original_level = Logger.level()
    Logger.configure(level: :error)

    prev_env = capture_env()

    Application.stop(:snakepit)
    configure_queue_env()
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    {:ok, counter} = Agent.start_link(fn -> %{count: 0, ids: MapSet.new()} end)
    QueueProbeAdapter.configure(counter: counter, delay: 500)

    on_exit(fn ->
      QueueProbeAdapter.reset!()
      if Process.alive?(counter), do: Agent.stop(counter)
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
      Logger.configure(level: original_level)
    end)

    {:ok, counter: counter}
  end

  test "requests that time out in queue never execute and queue saturations emit stats",
       %{counter: counter} do
    capture_log(fn ->
      results =
        Task.async_stream(
          1..10,
          fn idx ->
            Snakepit.execute("slow_probe", %{"request_id" => idx})
          end,
          max_concurrency: 10,
          timeout: 15_000
        )
        |> Enum.with_index(1)
        |> Enum.reduce(%{success: [], timeouts: [], saturated: []}, fn
          {{:ok, {:ok, _}}, id}, acc ->
            Map.update!(acc, :success, &[id | &1])

          {{:ok, {:error, :queue_timeout}}, id}, acc ->
            Map.update!(acc, :timeouts, &[id | &1])

          {{:ok, {:error, :pool_saturated}}, id}, acc ->
            Map.update!(acc, :saturated, &[id | &1])

          {{:exit, reason}, id}, _acc ->
            flunk("Request #{id} crashed with #{inspect(reason)}")
        end)

      assert results.timeouts != []
      assert results.saturated != []

      executed_ids =
        counter
        |> Agent.get(&Map.get(&1, :ids))
        |> MapSet.new()

      Enum.each(results.timeouts, fn id ->
        refute MapSet.member?(executed_ids, id),
               "Timed out request #{id} should not have been executed"
      end)

      stats = Snakepit.Pool.get_stats()
      assert stats.queue_timeouts == length(results.timeouts)
      assert stats.pool_saturated >= length(results.saturated)

      # We rely on Pool.trim_cancelled_requests/1 + stats assertions instead of peeking
      # into the global pool ETS state, which other async suites may mutate.
    end)
  end

  defp configure_queue_env do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_queue_timeout, 100)
    Application.put_env(:snakepit, :pool_max_queue_size, 5)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
    Application.put_env(:snakepit, :heartbeat, %{enabled: false})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: QueueProbeAdapter
      }
    ])

    Application.put_env(:snakepit, :adapter_module, QueueProbeAdapter)
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      pool_queue_timeout: Application.get_env(:snakepit, :pool_queue_timeout),
      pool_max_queue_size: Application.get_env(:snakepit, :pool_max_queue_size),
      adapter_module: Application.get_env(:snakepit, :adapter_module),
      heartbeat: Application.get_env(:snakepit, :heartbeat)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
