defmodule Snakepit.Pool.WorkerSupervisorTest do
  use Snakepit.TestCase, async: false

  @moduletag :capture_log

  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.Worker.StarterRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.TestAdapters.MockGRPCAdapter

  describe "stop_worker/1" do
    test "shuts down worker and starter when given a worker id" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      assert StarterRegistry.starter_exists?(worker_id)

      assert :ok = WorkerSupervisor.stop_worker(worker_id)

      assert_worker_shutdown(worker_id, worker_pid)
    end

    test "accepts a worker pid" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      assert :ok = WorkerSupervisor.stop_worker(worker_pid)

      assert_worker_shutdown(worker_id, worker_pid)
    end
  end

  describe "restart_worker/1" do
    test "terminates the existing worker and starts a fresh one" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      {:ok, new_starter_pid} = WorkerSupervisor.restart_worker(worker_id)
      assert is_pid(new_starter_pid)

      assert_eventually(fn ->
        match?({:ok, ^new_starter_pid}, StarterRegistry.get_starter_pid(worker_id))
      end)

      assert_eventually(fn ->
        case PoolRegistry.get_worker_pid(worker_id) do
          {:ok, new_pid} ->
            new_pid != worker_pid and Process.alive?(new_pid)

          {:error, :not_found} ->
            false
        end
      end)

      assert_eventually(fn -> not Process.alive?(worker_pid) end)
    end
  end

  defp start_mock_worker(worker_id) do
    worker_config = %{
      test_pid: self(),
      heartbeat: %{enabled: false}
    }

    {:ok, starter_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        MockGRPCAdapter,
        Snakepit.Pool,
        worker_config
      )

    assert is_pid(starter_pid)

    assert_eventually(
      fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
      timeout: 5_000,
      interval: 50
    )

    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)

    {starter_pid, worker_pid}
  end

  defp assert_worker_shutdown(worker_id, worker_pid) do
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert_eventually(fn ->
      match?({:error, :not_found}, PoolRegistry.get_worker_pid(worker_id))
    end)

    assert_eventually(fn -> not StarterRegistry.starter_exists?(worker_id) end)
  end

  defp unique_worker_id do
    "worker_supervisor_test_#{System.unique_integer([:positive])}"
  end
end
