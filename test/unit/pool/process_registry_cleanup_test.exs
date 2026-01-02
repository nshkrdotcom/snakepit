defmodule Snakepit.Pool.ProcessRegistryCleanupTest do
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller

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

  test "manual orphan cleanup removes stale entries with live non-beam os pid" do
    state = :sys.get_state(ProcessRegistry)
    dets = state.dets_table
    current_run = state.beam_run_id

    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    {:os_pid, other_os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      safe_close_port(port)
    end)

    stale_worker = "stale_pid_reuse_#{System.unique_integer([:positive])}"

    stale_entry = %{
      process_pid: 99_991,
      beam_run_id: "run_#{System.unique_integer([:positive])}",
      beam_os_pid: other_os_pid,
      registered_at: System.system_time(:second)
    }

    :dets.insert(dets, {stale_worker, stale_entry})
    :dets.sync(dets)

    on_exit(fn ->
      :dets.delete(dets, stale_worker)
      :dets.sync(dets)
    end)

    ProcessRegistry.manual_orphan_cleanup()

    assert current_run != stale_entry.beam_run_id
    assert :dets.lookup(dets, stale_worker) == []
  end

  test "cleanup_dead_workers keeps entries while external process is alive" do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    {:os_pid, process_pid} = Port.info(port, :os_pid)

    on_exit(fn -> safe_close_port(port) end)

    worker_id = "cleanup_dead_alive_#{System.unique_integer([:positive])}"

    elixir_pid =
      spawn(fn ->
        receive do
        after
          10 -> :ok
        end
      end)

    Process.exit(elixir_pid, :kill)

    assert :ok = ProcessRegistry.activate_worker(worker_id, elixir_pid, process_pid, "test")

    ProcessRegistry.cleanup_dead_workers()

    TestHelpers.assert_eventually(fn ->
      case ProcessRegistry.get_worker_info(worker_id) do
        {:ok, info} ->
          info.process_pid == process_pid and Map.get(info, :terminating?) == true

        _ ->
          false
      end
    end)

    assert :ok = ProcessKiller.kill_with_escalation(process_pid, 1_000)
    TestHelpers.assert_eventually(fn -> not ProcessKiller.process_alive?(process_pid) end)
    safe_close_port(port)

    ProcessRegistry.cleanup_dead_workers()

    TestHelpers.assert_eventually(fn ->
      match?({:error, :not_found}, ProcessRegistry.get_worker_info(worker_id))
    end)
  end

  test "unregister_worker defers removal while external process is alive" do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    {:os_pid, process_pid} = Port.info(port, :os_pid)

    on_exit(fn -> safe_close_port(port) end)

    worker_id = "unregister_defers_#{System.unique_integer([:positive])}"

    assert :ok = ProcessRegistry.activate_worker(worker_id, self(), process_pid, "test")

    ProcessRegistry.unregister_worker(worker_id)

    TestHelpers.assert_eventually(fn ->
      case ProcessRegistry.get_worker_info(worker_id) do
        {:ok, info} -> info.process_pid == process_pid and Map.get(info, :terminating?) == true
        _ -> false
      end
    end)

    assert :ok = ProcessKiller.kill_with_escalation(process_pid, 1_000)
    TestHelpers.assert_eventually(fn -> not ProcessKiller.process_alive?(process_pid) end)
    safe_close_port(port)

    ProcessRegistry.unregister_worker(worker_id)

    TestHelpers.assert_eventually(fn ->
      match?({:error, :not_found}, ProcessRegistry.get_worker_info(worker_id))
    end)
  end

  defp safe_close_port(port) when is_port(port) do
    Port.close(port)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end
end
