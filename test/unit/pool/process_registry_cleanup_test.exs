defmodule Snakepit.Pool.ProcessRegistryCleanupTest do
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller

  setup do
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :ok
  end

  test "registry process traps exits so terminate callback runs on shutdown" do
    pid = Process.whereis(ProcessRegistry)
    assert is_pid(pid)
    assert {:trap_exit, true} = Process.info(pid, :trap_exit)
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

  test "terminate waits for in-flight cleanup task before closing DETS" do
    dets = open_temp_dets()
    gate_ref = make_ref()
    cleanup_pid = spawn(fn -> wait_for_cleanup_release(gate_ref) end)

    task =
      Task.async(fn ->
        cleanup_ref = Process.monitor(cleanup_pid)

        state = %ProcessRegistry{
          table: :snakepit_pool_process_registry,
          dets_table: dets,
          beam_run_id: "test_run",
          beam_os_pid: System.pid() |> String.to_integer(),
          instance_name: "test",
          allow_missing_instance: true,
          instance_token: "test_token",
          allow_missing_token: true,
          cleanup_task_runner: fn _, _, _, _, _, _, _ -> :ok end,
          cleanup_task_pid: cleanup_pid,
          cleanup_task_ref: cleanup_ref,
          cleanup_task_kind: :manual
        }

        ProcessRegistry.terminate(:shutdown, state)
      end)

    assert Task.yield(task, 50) == nil

    send(cleanup_pid, {:release_cleanup, gate_ref})
    assert :ok = Task.await(task, 1_000)

    refute Process.alive?(cleanup_pid)
  end

  test "terminate timeout path kills cleanup task and flushes monitor" do
    previous_timeout = Application.get_env(:snakepit, :cleanup_on_stop_timeout_ms)
    Application.put_env(:snakepit, :cleanup_on_stop_timeout_ms, 40)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:snakepit, :cleanup_on_stop_timeout_ms)
      else
        Application.put_env(:snakepit, :cleanup_on_stop_timeout_ms, previous_timeout)
      end
    end)

    dets = open_temp_dets()
    cleanup_pid = spawn(fn -> wait_forever_for_cleanup_release() end)

    task =
      Task.async(fn ->
        cleanup_ref = Process.monitor(cleanup_pid)

        state = %ProcessRegistry{
          table: :snakepit_pool_process_registry,
          dets_table: dets,
          beam_run_id: "test_run",
          beam_os_pid: System.pid() |> String.to_integer(),
          instance_name: "test",
          allow_missing_instance: true,
          instance_token: "test_token",
          allow_missing_token: true,
          cleanup_task_runner: fn _, _, _, _, _, _, _ -> :ok end,
          cleanup_task_pid: cleanup_pid,
          cleanup_task_ref: cleanup_ref,
          cleanup_task_kind: :manual
        }

        assert :ok = ProcessRegistry.terminate(:shutdown, state)

        # Timeout path should demonitor with :flush so no late DOWN remains.
        refute_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_pid, _reason}
        :ok
      end)

    assert :ok = Task.await(task, 1_000)
    refute Process.alive?(cleanup_pid)
  end

  defp safe_close_port(port) when is_port(port) do
    Port.close(port)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  defp open_temp_dets do
    unique = System.unique_integer([:positive])
    table_name = :snakepit_process_registry_terminate_test
    file_path = Path.join(System.tmp_dir!(), "snakepit_process_registry_terminate_#{unique}.dets")

    {:ok, table} =
      :dets.open_file(table_name, [
        {:file, to_charlist(file_path)},
        {:type, :set},
        {:auto_save, 1_000}
      ])

    on_exit(fn ->
      safe_close_dets(table)
      File.rm(file_path)
    end)

    table
  end

  defp wait_for_cleanup_release(gate_ref) do
    receive do
      {:release_cleanup, ^gate_ref} -> :ok
    end
  end

  defp wait_forever_for_cleanup_release do
    receive do
      {:release_cleanup, _ref} -> :ok
    end
  end

  defp safe_close_dets(table) do
    :dets.close(table)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end
end
