defmodule Snakepit.Pool.InitTaskStateTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  test "init-task normal down keeps tracking state until completion payload arrives" do
    task_pid =
      spawn(fn ->
        receive do
        end
      end)

    task_ref = Process.monitor(task_pid)
    affinity_cache = :ets.new(:pool_init_task_state_cache, [:set, :private])

    state = %Pool{
      pools: %{},
      affinity_cache: affinity_cache,
      default_pool: :default,
      initializing: true,
      init_task_ref: task_ref,
      init_task_pid: task_pid
    }

    assert {:noreply, new_state} =
             Pool.handle_info({:DOWN, task_ref, :process, task_pid, :normal}, state)

    assert new_state.init_task_ref == task_ref
    assert new_state.init_task_pid == task_pid
  end

  test "init-task completion payload clears tracked init task state" do
    task_pid =
      spawn(fn ->
        receive do
        end
      end)

    task_ref = Process.monitor(task_pid)
    affinity_cache = :ets.new(:pool_init_task_state_cache, [:set, :private])

    state = %Pool{
      pools: %{},
      affinity_cache: affinity_cache,
      default_pool: :default,
      initializing: true,
      init_task_ref: task_ref,
      init_task_pid: task_pid,
      init_start_time: System.monotonic_time(:millisecond),
      init_complete_waiters: []
    }

    updated_pool = %{
      name: :default,
      size: 1,
      workers: ["w1"],
      available: MapSet.new(),
      ready_workers: MapSet.new(),
      init_failed: false,
      worker_loads: %{},
      worker_capacities: %{},
      capacity_strategy: :pool,
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: %{requests: 0, queued: 0, errors: 0, queue_timeouts: 0, pool_saturated: 0},
      initialized: false,
      startup_timeout: 1_000,
      queue_timeout: 1_000,
      max_queue_size: 100,
      worker_module: Snakepit.GRPCWorker,
      adapter_module: Snakepit.TestAdapters.MockGRPCAdapter,
      pool_config: %{},
      initialization_waiters: []
    }

    assert {:noreply, new_state} =
             Pool.handle_info({task_ref, {:pool_init_complete, %{default: updated_pool}}}, state)

    assert new_state.init_task_ref == nil
    assert new_state.init_task_pid == nil
  end
end
