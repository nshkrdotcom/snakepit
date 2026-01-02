defmodule Snakepit.Pool.WorkerFlowIntegrationTest do
  use ExUnit.Case, async: false

  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Test.MockGRPCWorker

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    Application.load(:snakepit)
    configure_pooling()

    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

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
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
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

  defp configure_pooling do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
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
