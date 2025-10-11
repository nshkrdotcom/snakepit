defmodule Snakepit.ProcessKillerTest do
  use ExUnit.Case
  require Logger

  @moduletag :integration

  describe "process_alive?/1" do
    test "detects alive process" do
      # Use our own PID (converted to OS PID)
      our_os_pid = System.get_pid() |> String.to_integer()
      assert Snakepit.ProcessKiller.process_alive?(our_os_pid)
    end

    test "detects dead process" do
      # PID 999999 is unlikely to exist
      refute Snakepit.ProcessKiller.process_alive?(999_999)
    end

    test "handles non-integer input" do
      refute Snakepit.ProcessKiller.process_alive?(nil)
      refute Snakepit.ProcessKiller.process_alive?("string")
    end
  end

  describe "get_process_command/1" do
    test "gets command for existing process" do
      # Get our own process command
      our_os_pid = System.get_pid() |> String.to_integer()
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

      # Give it a moment to die
      Process.sleep(100)

      # Should be dead now
      refute Snakepit.ProcessKiller.process_alive?(pid)
    end

    test "returns ok for already-dead process" do
      # Kill a non-existent PID
      assert :ok = Snakepit.ProcessKiller.kill_process(999_999, :sigterm)
    end
  end

  describe "kill_with_escalation/2" do
    test "kills process gracefully with SIGTERM" do
      # Spawn a sleep process
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with escalation
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 1000)

      # Should be dead
      refute Snakepit.ProcessKiller.process_alive?(pid)
    end

    test "escalates to SIGKILL if process doesn't die" do
      # Spawn a process that ignores SIGTERM
      # (using cat which will die to SIGKILL)
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with short timeout (will escalate)
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 100)

      # Should be dead from SIGKILL
      refute Snakepit.ProcessKiller.process_alive?(pid)
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
    @tag timeout: 10_000
    test "kills processes matching run_id" do
      # Generate a unique run_id for this test
      test_run_id = Snakepit.RunID.generate()

      # Spawn a dummy Python process with our run_id
      # We'll use sleep with a marker in the command line
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

      # Give it time to show up in process list
      Process.sleep(100)

      # Now kill by run_id
      assert {:ok, killed_count} = Snakepit.ProcessKiller.kill_by_run_id(test_run_id)
      assert killed_count >= 1

      # Give it time to die
      Process.sleep(500)

      # Should be dead
      refute Snakepit.ProcessKiller.process_alive?(pid)
    end

    test "returns 0 for non-existent run_id" do
      fake_run_id = "zzz9999"
      assert {:ok, 0} = Snakepit.ProcessKiller.kill_by_run_id(fake_run_id)
    end
  end
end
