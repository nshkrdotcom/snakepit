defmodule Snakepit.Pool.WorkerFlowIntegrationTest do
  use ExUnit.Case, async: false

  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Test.MockGRPCWorker

  setup do
    {:ok, _} = Application.ensure_all_started(:snakepit)

    worker_id = "integration_worker_#{System.unique_integer([:positive])}"

    worker_config = %{
      pool_identifier: :integration_test,
      heartbeat: %{enabled: false}
    }

    {:ok, _starter_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        MockGRPCWorker,
        Snakepit.TestAdapters.MockGRPCAdapter,
        self(),
        worker_config
      )

    assert_eventually(fn -> ProcessRegistry.worker_registered?(worker_id) end,
      timeout: 5_000,
      interval: 50
    )

    on_exit(fn ->
      WorkerSupervisor.stop_worker(worker_id)
    end)

    {:ok, %{worker_id: worker_id}}
  end

  test "worker executes requests and remains tracked", %{worker_id: worker_id} do
    {:ok, result} = MockGRPCWorker.execute(worker_id, "ping", %{}, 5_000)
    assert result["status"] == "pong"

    assert ProcessRegistry.worker_registered?(worker_id)
    assert match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id))
  end

  test "worker crash triggers restart and future requests succeed", %{worker_id: worker_id} do
    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)
    Process.exit(worker_pid, :kill)

    assert_eventually(
      fn ->
        case PoolRegistry.get_worker_pid(worker_id) do
          {:ok, new_pid} when is_pid(new_pid) and new_pid != worker_pid -> true
          _ -> false
        end
      end,
      timeout: 5_000,
      interval: 50
    )

    {:ok, result} = MockGRPCWorker.execute(worker_id, "ping", %{}, 5_000)
    assert result["status"] == "pong"
    assert ProcessRegistry.worker_registered?(worker_id)
  end
end
