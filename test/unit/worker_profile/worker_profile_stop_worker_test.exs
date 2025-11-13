defmodule Snakepit.WorkerProfileStopWorkerTest do
  use Snakepit.TestCase, async: false

  @moduletag :capture_log

  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.Worker.StarterRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.TestAdapters.MockGRPCAdapter
  alias Snakepit.WorkerProfile.Process, as: ProcessProfile
  alias Snakepit.WorkerProfile.Thread, as: ThreadProfile

  test "process profile stop_worker/1 shuts down the worker when given a pid" do
    worker_id = unique_worker_id()
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
    {_starter_pid, worker_pid} = start_mock_worker(worker_id)

    assert :ok = ProcessProfile.stop_worker(worker_pid)

    assert_worker_shutdown(worker_id, worker_pid)
  end

  test "thread profile stop_worker/1 shuts down the worker when given a pid" do
    worker_id = unique_worker_id()
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
    {_starter_pid, worker_pid} = start_mock_worker(worker_id)

    assert :ok = ThreadProfile.stop_worker(worker_pid)

    assert_worker_shutdown(worker_id, worker_pid)
  end

  test "workers expose lifecycle config metadata" do
    worker_id = unique_worker_id()
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
    {_starter_pid, worker_pid} = start_mock_worker(worker_id)

    state = :sys.get_state(worker_pid)

    assert state.worker_config.worker_module == Snakepit.GRPCWorker
    assert state.worker_config.adapter_module == MockGRPCAdapter
    assert state.worker_config.pool_name == Snakepit.Pool

    :ok = GenServer.stop(worker_pid)
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
    "worker_profile_test_#{System.unique_integer([:positive])}"
  end
end
