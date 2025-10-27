defmodule ThreadCapacityStoreTest do
  use ExUnit.Case, async: true

  alias Snakepit.WorkerProfile.Thread.CapacityStore

  setup do
    {:ok, _pid} = CapacityStore.ensure_started()
    :ok
  end

  test "tracks capacity and load through the GenServer owner" do
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
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
end
