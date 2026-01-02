defmodule Snakepit.RuntimeCleanupTest do
  use ExUnit.Case, async: false

  alias Snakepit.ProcessKiller
  alias Snakepit.RuntimeCleanup

  test "run/2 terminates tracked processes" do
    port =
      Port.open({:spawn_executable, "/bin/cat"}, [
        :binary,
        :exit_status
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn -> safe_close_port(port) end)

    entries = [
      {"runtime_cleanup_worker", %{process_pid: pid, pgid: nil, process_group?: false}}
    ]

    assert ProcessKiller.process_alive?(pid)
    assert :ok = RuntimeCleanup.run(entries, timeout_ms: 500, poll_interval_ms: 20)
    assert wait_for_death(pid, 2_000)
  end

  defp wait_for_death(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_death_loop(pid, deadline)
  end

  defp wait_for_death_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      if ProcessKiller.process_alive?(pid) do
        receive do
        after
          50 -> :ok
        end

        wait_for_death_loop(pid, deadline)
      else
        true
      end
    end
  end

  defp safe_close_port(port) when is_port(port) do
    Port.close(port)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end
end
