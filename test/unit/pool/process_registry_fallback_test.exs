defmodule Snakepit.Pool.ProcessRegistryFallbackTest do
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry

  test "manual cleanup fallback does not block callback mailbox when TaskSupervisor is unavailable" do
    on_exit(fn ->
      Application.ensure_all_started(:snakepit)
    end)

    Application.stop(:snakepit)
    gate_ref = make_ref()
    parent = self()

    cleanup_runner = fn _dets,
                        _run_id,
                        _beam_pid,
                        _instance,
                        _allow_missing,
                        _token,
                        _allow_token ->
      send(parent, {:cleanup_runner_started, gate_ref, self()})

      receive do
        {:release_cleanup_runner, ^gate_ref} -> :ok
      end
    end

    {:ok, _registry} = start_supervised({ProcessRegistry, cleanup_runner: cleanup_runner})

    state = :sys.get_state(ProcessRegistry)
    dets = state.dets_table

    Enum.each(1..4_000, fn idx ->
      worker_id = "fallback_cleanup_#{idx}_#{System.unique_integer([:positive])}"

      :dets.insert(dets, {
        worker_id,
        %{
          status: :active,
          process_pid: 90_000 + idx,
          beam_run_id: "old_run_#{idx}",
          beam_os_pid: 99_999_999
        }
      })
    end)

    :dets.sync(dets)

    cleanup_task =
      Task.async(fn ->
        ProcessRegistry.manual_orphan_cleanup()
      end)

    assert_receive {:cleanup_runner_started, ^gate_ref, cleanup_runner_pid}, 1_000

    assert run_id = ProcessRegistry.get_beam_run_id()
    assert is_binary(run_id)

    send(cleanup_runner_pid, {:release_cleanup_runner, gate_ref})
    assert :ok = Task.await(cleanup_task, 15_000)
  end
end
