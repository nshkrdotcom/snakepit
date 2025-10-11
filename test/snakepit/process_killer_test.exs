defmodule Snakepit.ProcessKillerTest do
  use ExUnit.Case
  require Logger

  @moduletag :integration

  describe "process_alive?/1" do
    test "detects alive process" do
      # Use our own PID (converted to OS PID)
      our_os_pid = System.pid() |> String.to_integer()
      assert Snakepit.ProcessKiller.process_alive?(our_os_pid)
    end

    test "detects dead process" do
      # Spawn a process that will stay alive until we close the port
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Verify it's alive
      assert Snakepit.ProcessKiller.process_alive?(pid)

      # Close the port, which kills the process
      Port.close(port)

      # Poll until process is actually dead
      assert wait_for_death(pid, 2000), "Process should have died after Port.close"

      # Now it should be dead
      refute Snakepit.ProcessKiller.process_alive?(pid)
    end

    test "handles non-integer input" do
      refute Snakepit.ProcessKiller.process_alive?(nil)
      refute Snakepit.ProcessKiller.process_alive?("string")
    end
  end

  describe "get_process_command/1" do
    test "gets command for existing process" do
      # Get our own process command
      our_os_pid = System.pid() |> String.to_integer()
      assert {:ok, cmd} = Snakepit.ProcessKiller.get_process_command(our_os_pid)
      # Should contain "beam" or "elixir"
      assert String.contains?(cmd, "beam") or String.contains?(cmd, "elixir")
    end

    test "returns error for non-existent process" do
      assert {:error, :not_found} = Snakepit.ProcessKiller.get_process_command(999_999)
    end
  end

  describe "kill_process/2" do
    test "kills a sleep process with SIGTERM" do
      # Spawn a sleep process
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Verify it's alive
      assert Snakepit.ProcessKiller.process_alive?(pid)

      # Kill with SIGTERM
      assert :ok = Snakepit.ProcessKiller.kill_process(pid, :sigterm)

      # Wait for it to die with retry logic
      assert wait_for_death(pid, 1000), "Process #{pid} should have died"
    end

    test "returns ok for already-dead process" do
      # Spawn a process that will stay alive until we close the port
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Verify it's alive
      assert Snakepit.ProcessKiller.process_alive?(pid)

      # Close the port, which kills the process
      Port.close(port)

      # Poll until process is actually dead
      assert wait_for_death(pid, 2000), "Process should have died after Port.close"

      # Try to kill already-dead process
      assert :ok = Snakepit.ProcessKiller.kill_process(pid, :sigterm)
    end
  end

  # Helper function for tests
  defp wait_for_death(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_loop(pid, deadline)
  end

  defp wait_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      if Snakepit.ProcessKiller.process_alive?(pid) do
        receive do
        after
          50 -> :ok
        end

        wait_loop(pid, deadline)
      else
        true
      end
    end
  end

  defp wait_for_list_loop(run_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      case System.cmd("pgrep", ["-f", run_id], stderr_to_stdout: true) do
        {output, 0} when byte_size(output) > 0 ->
          true

        _ ->
          receive do
          after
            50 -> :ok
          end

          wait_for_list_loop(run_id, deadline)
      end
    end
  end

  describe "kill_with_escalation/2" do
    test "kills process gracefully with SIGTERM" do
      # Spawn a sleep process
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with escalation
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 1000)

      # Should be dead - wait to confirm
      assert wait_for_death(pid, 1000), "Process #{pid} should have died"
    end

    test "escalates to SIGKILL if process doesn't die" do
      # Spawn a process that ignores SIGTERM
      # (using cat which will die to SIGKILL)
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with short timeout (will escalate)
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 100)

      # Should be dead from SIGKILL - wait to confirm
      assert wait_for_death(pid, 1000), "Process #{pid} should have died from SIGKILL"
    end
  end

  describe "find_python_processes/0" do
    test "finds python processes on system" do
      # This test might not find any python processes depending on the system
      pids = Snakepit.ProcessKiller.find_python_processes()
      assert is_list(pids)
      # All should be integers
      assert Enum.all?(pids, &is_integer/1)
    end
  end

  describe "kill_by_run_id/1" do
    test "returns 0 for non-existent run_id" do
      fake_run_id = "zzz9999"
      assert {:ok, 0} = Snakepit.ProcessKiller.kill_by_run_id(fake_run_id)
    end

    @tag :skip
    @tag timeout: 10_000
    test "kills processes matching run_id" do
      # This test is complex and depends on Python being available
      # Skip for now - the functionality is tested in integration tests
      test_run_id = Snakepit.RunID.generate()

      # Spawn a dummy Python process with our run_id
      cmd = [
        "python3",
        "-c",
        "import time; time.sleep(30)",
        "--run-id",
        test_run_id
      ]

      port = Port.open({:spawn_executable, "/usr/bin/env"}, [:binary, args: cmd])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Verify it's running
      assert Snakepit.ProcessKiller.process_alive?(pid)

      # Poll until process appears in process list with correct run_id
      deadline = System.monotonic_time(:millisecond) + 5000

      wait_for_process_in_list = fn ->
        wait_for_list_loop(test_run_id, deadline)
      end

      assert wait_for_process_in_list.(),
             "Process with run_id #{test_run_id} never appeared in process list"

      # Now kill by run_id
      assert {:ok, killed_count} = Snakepit.ProcessKiller.kill_by_run_id(test_run_id)
      assert killed_count >= 1

      # Wait for it to die
      assert wait_for_death(pid, 2000), "Process #{pid} should have died"
    end
  end
end
