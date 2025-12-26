defmodule Snakepit.Pool.RandomWorkerFlowTest do
  use ExUnit.Case, async: false

  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Test.MockGRPCWorker

  @moduletag :capture_log
  @worker_count 3
  @iterations 15

  setup_all do
    :rand.seed(:exsss, {System.system_time(), System.monotonic_time(), 0})
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:snakepit)

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
end
