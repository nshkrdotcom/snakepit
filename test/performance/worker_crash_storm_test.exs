defmodule Snakepit.Performance.WorkerCrashStormTest do
  @moduledoc """
  Verifies that the pool self-heals when multiple workers crash while requests
  continue to flow through the system.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller

  @moduletag :performance
  @pool_size 8
  @crash_cycles 30

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    configure_mock_pool()
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  test "pool recovers from repeated worker crashes under load" do
    {:ok, tracker} = start_supervised({Agent, fn -> [] end})

    load_task = Task.async(fn -> run_compute_load(200, 16) end)
    crash_task = Task.async(fn -> induce_crashes(@crash_cycles, tracker) end)

    Task.await(load_task, 60_000)
    Task.await(crash_task, 60_000)

    assert_eventually(
      fn -> length(Snakepit.Pool.list_workers()) == @pool_size end,
      timeout: 30_000,
      interval: 200
    )

    stats = Snakepit.Pool.get_stats()
    assert stats.errors < 80
    assert stats.workers == @pool_size

    # Wait for registry to mostly clean up dead workers
    # Note: some dead workers may still be in registry briefly due to async cleanup
    assert_eventually(
      fn ->
        stats = ProcessRegistry.get_stats()
        # Allow up to 2 dead workers during cleanup
        stats.dead_workers <= 2
      end,
      timeout: 10_000,
      interval: 200
    )

    registry_stats = ProcessRegistry.get_stats()
    # Active processes should be close to pool size (allow some variance)
    assert registry_stats.active_process_pids <= @pool_size + 4

    killed_pids = Agent.get(tracker, &Enum.uniq/1)

    Enum.each(killed_pids, fn pid ->
      assert_eventually(fn -> not ProcessKiller.process_alive?(pid) end, timeout: 5_000)
    end)
  end

  defp run_compute_load(total_requests, concurrency) do
    Task.async_stream(
      1..total_requests,
      fn idx ->
        Snakepit.execute("compute", %{"idx" => idx})
      end,
      max_concurrency: concurrency,
      timeout: 15_000
    )
    |> Stream.run()
  end

  defp induce_crashes(iterations, tracker) do
    Enum.each(1..iterations, fn _cycle ->
      worker_ids = Snakepit.Pool.list_workers()

      worker_ids
      |> Enum.shuffle()
      |> Enum.take(2)
      |> Enum.each(&kill_worker(&1, tracker))

      receive do
      after
        25 -> :ok
      end
    end)
  end

  defp kill_worker(worker_id, tracker) do
    with {:ok, pid} <- Snakepit.Pool.Registry.get_worker_pid(worker_id),
         {:ok, info} <- ProcessRegistry.get_worker_info(worker_id) do
      Agent.update(tracker, &[info.process_pid | &1])
      Process.exit(pid, :kill)
    else
      _ -> :ok
    end
  end

  defp configure_mock_pool do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: @pool_size})
    Application.put_env(:snakepit, :pool_reconcile_interval_ms, 200)
    Application.put_env(:snakepit, :pool_reconcile_batch_size, 4)
    Application.put_env(:snakepit, :worker_starter_max_restarts, 200)
    Application.put_env(:snakepit, :worker_starter_max_seconds, 10)
    Application.put_env(:snakepit, :worker_supervisor_max_restarts, 200)
    Application.put_env(:snakepit, :worker_supervisor_max_seconds, 10)

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: @pool_size,
        adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
      }
    ])

    Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockGRPCAdapter)
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      pool_reconcile_interval_ms: Application.get_env(:snakepit, :pool_reconcile_interval_ms),
      pool_reconcile_batch_size: Application.get_env(:snakepit, :pool_reconcile_batch_size),
      worker_starter_max_restarts: Application.get_env(:snakepit, :worker_starter_max_restarts),
      worker_starter_max_seconds: Application.get_env(:snakepit, :worker_starter_max_seconds),
      worker_supervisor_max_restarts:
        Application.get_env(:snakepit, :worker_supervisor_max_restarts),
      worker_supervisor_max_seconds:
        Application.get_env(:snakepit, :worker_supervisor_max_seconds),
      adapter_module: Application.get_env(:snakepit, :adapter_module)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
