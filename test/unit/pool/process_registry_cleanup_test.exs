defmodule Snakepit.Pool.ProcessRegistryCleanupTest do
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry

  setup do
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :ok
  end

  test "manual orphan cleanup removes stale DETS entries but keeps current run" do
    state = :sys.get_state(ProcessRegistry)
    dets = state.dets_table
    current_run = state.beam_run_id
    current_os_pid = state.beam_os_pid

    stale_worker = "stale_cleanup_#{System.unique_integer([:positive])}"
    current_worker = "current_cleanup_#{System.unique_integer([:positive])}"

    stale_entry = %{
      status: :active,
      process_pid: 99_999,
      beam_run_id: "run_#{System.unique_integer([:positive])}",
      beam_os_pid: 9_999_999
    }

    current_entry = %{
      status: :active,
      process_pid: 77_777,
      beam_run_id: current_run,
      beam_os_pid: current_os_pid
    }

    :dets.insert(dets, {stale_worker, stale_entry})
    :dets.insert(dets, {current_worker, current_entry})
    :dets.sync(dets)

    on_exit(fn ->
      :dets.delete(dets, current_worker)
      :dets.sync(dets)
    end)

    ProcessRegistry.manual_orphan_cleanup()

    assert :dets.lookup(dets, stale_worker) == []
    assert :dets.lookup(dets, current_worker) == [{current_worker, current_entry}]
  end
end
