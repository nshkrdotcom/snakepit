defmodule Snakepit.Pool.RandomWorkerFlowTest do
  use ExUnit.Case, async: false

  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Test.MockGRPCWorker

  @moduletag :capture_log
  @moduletag :slow
  @worker_count 3
  @iterations 10

  setup_all do
    :rand.seed(:exsss, {System.system_time(), System.monotonic_time(), 0})
    :ok
  end

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    configure_pool()
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    initial_workers =
      for _ <- 1..@worker_count do
        start_test_worker()
      end

    Process.put(:prop_workers, MapSet.new(initial_workers))

    on_exit(fn ->
      Process.get(:prop_workers, MapSet.new())
      |> Enum.each(fn worker_id ->
        _ = WorkerSupervisor.stop_worker(worker_id)

        assert_eventually(fn -> ProcessRegistry.worker_registered?(worker_id) == false end,
          timeout: 5_000,
          interval: 50
        )
      end)

      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)

      if prev_env.pooling_enabled do
        assert_eventually(
          fn ->
            Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
          end,
          timeout: 30_000,
          interval: 1_000
        )
      end
    end)

    {:ok, %{worker_ids: initial_workers}}
  end

  test "random executes / kills / restarts preserve registry invariants", %{
    worker_ids: worker_ids
  } do
    Enum.each(1..@iterations, fn iteration ->
      case rem(iteration, 2) do
        0 -> random_execute(worker_ids)
        _ -> kill_and_wait(Enum.random(worker_ids))
      end
    end)

    assert_registry_consistent(worker_ids)
  end

  defp start_test_worker do
    worker_id = "prop_worker_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        MockGRPCWorker,
        Snakepit.TestAdapters.MockGRPCAdapter,
        Snakepit.Pool,
        %{heartbeat: %{enabled: false}, pool_identifier: :property_pool}
      )

    assert_eventually(fn -> ProcessRegistry.worker_registered?(worker_id) end,
      timeout: 5_000,
      interval: 50
    )

    Process.put(:prop_workers, MapSet.put(Process.get(:prop_workers, MapSet.new()), worker_id))

    worker_id
  end

  defp random_execute(worker_ids) do
    worker_id = Enum.random(worker_ids)

    Task.async(fn ->
      MockGRPCWorker.execute(worker_id, "ping", %{}, 5_000)
    end)
    |> Task.await(5_000)
  end

  defp kill_and_wait(worker_id) do
    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)
    Process.exit(worker_pid, :kill)

    assert_eventually(
      fn ->
        case PoolRegistry.get_worker_pid(worker_id) do
          {:ok, new_pid} when is_pid(new_pid) and new_pid != worker_pid ->
            ProcessRegistry.worker_registered?(worker_id)

          _ ->
            false
        end
      end,
      timeout: 5_000,
      interval: 50
    )
  end

  defp assert_registry_consistent(worker_ids) do
    entries = ProcessRegistry.list_all_workers() |> Map.new()

    for worker_id <- worker_ids do
      assert Map.has_key?(entries, worker_id),
             "expected #{worker_id} in ProcessRegistry entries: #{inspect(Map.keys(entries))}"

      assert match?({:ok, pid} when is_pid(pid), PoolRegistry.get_worker_pid(worker_id))
    end
  end

  defp configure_pool do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.delete_env(:snakepit, :pools)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
    Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockGRPCAdapter)
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      adapter_module: Application.get_env(:snakepit, :adapter_module)
    }
  end

  defp restore_env(env) do
    restore_key(:pooling_enabled, env.pooling_enabled)
    restore_key(:pools, env.pools)
    restore_key(:pool_config, env.pool_config)
    restore_key(:adapter_module, env.adapter_module)
  end

  defp restore_key(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_key(key, value), do: Application.put_env(:snakepit, key, value)
end
