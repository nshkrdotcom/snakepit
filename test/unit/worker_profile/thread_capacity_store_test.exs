defmodule ThreadCapacityStoreTest do
  use ExUnit.Case, async: false

  alias Snakepit.WorkerProfile.Thread.CapacityStore

  setup do
    start_supervised!(CapacityStore)
    :ok
  end

  test "tracks capacity and load through the GenServer owner" do
    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker_pid, :kill) end)

    assert :ok = CapacityStore.track_worker(worker_pid, 2)
    assert 2 == CapacityStore.get_capacity(worker_pid)
    assert 0 == CapacityStore.get_load(worker_pid)

    assert {:ok, 2, 1} = CapacityStore.check_and_increment_load(worker_pid)
    assert {:ok, 2, 2} = CapacityStore.check_and_increment_load(worker_pid)
    assert {:at_capacity, 2, 2} = CapacityStore.check_and_increment_load(worker_pid)

    CapacityStore.decrement_load(worker_pid)
    assert 1 == CapacityStore.get_load(worker_pid)

    assert :ok = CapacityStore.untrack_worker(worker_pid)
  end

  test "rejects direct ETS writes from external processes" do
    assert_raise ArgumentError, fn ->
      :ets.insert(CapacityStore.table_name(), {self(), 10, 0})
    end
  end

  test "returns controlled error instead of exiting when store is unavailable" do
    pid = Process.whereis(CapacityStore)
    assert is_pid(pid)
    :ok = GenServer.stop(pid, :normal)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker_pid, :kill) end)

    assert {:error, :capacity_store_unavailable} =
             CapacityStore.check_and_increment_load(pid, worker_pid)

    # Name-based calls can observe either unavailable store or a restarted empty store.
    assert CapacityStore.check_and_increment_load(worker_pid) in [
             {:error, :capacity_store_unavailable},
             {:error, :unknown_worker}
           ]
  end
end
