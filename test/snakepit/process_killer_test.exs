defmodule Snakepit.ProcessKillerTest do
  use ExUnit.Case
  require Logger

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Test.ProcessLeakTracker

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

  describe "get_process_group_id/1" do
    test "returns pgid for existing process" do
      our_os_pid = System.pid() |> String.to_integer()
      assert {:ok, pgid} = Snakepit.ProcessKiller.get_process_group_id(our_os_pid)
      assert is_integer(pgid)
    end

    test "returns error for non-existent process" do
      assert {:error, :not_found} = Snakepit.ProcessKiller.get_process_group_id(999_999)
    end
  end

  describe "kill_process/2" do
    test "kills a blocking process with SIGTERM" do
      # Spawn a blocking process
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
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

  defp safe_close_port(port) when is_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    if is_integer(os_pid) do
      ProcessLeakTracker.unregister_pid(os_pid)
      _ = Snakepit.ProcessKiller.kill_with_escalation(os_pid, 1_000)
    end

    Port.close(port)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  defp read_pids(port, expected_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_pids_loop(port, "", expected_count, deadline)
  end

  defp read_pids_loop(port, buffer, expected_count, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("Timed out waiting for PID output")
    else
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> to_string(data)

          pids =
            Regex.scan(~r/(\d+)/, buffer)
            |> Enum.map(fn [_, pid_str] -> String.to_integer(pid_str) end)

          if length(pids) >= expected_count do
            Enum.take(pids, expected_count)
          else
            read_pids_loop(port, buffer, expected_count, deadline)
          end
      after
        50 ->
          read_pids_loop(port, buffer, expected_count, deadline)
      end
    end
  end

  describe "kill_with_escalation/2" do
    test "kills process gracefully with SIGTERM" do
      # Spawn a blocking process
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with escalation
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 1000)

      # Should be dead - wait to confirm
      assert wait_for_death(pid, 1000), "Process #{pid} should have died"
    end

    test "escalates to SIGKILL if process doesn't die" do
      # Spawn a process that ignores SIGTERM (forces escalation)
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "trap '' TERM; exec /bin/cat"]
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)

      # Kill with short timeout (will escalate)
      assert :ok = Snakepit.ProcessKiller.kill_with_escalation(pid, 100)

      # Should be dead from SIGKILL - wait to confirm
      assert wait_for_death(pid, 1000), "Process #{pid} should have died from SIGKILL"
    end
  end

  describe "kill_process_group_with_escalation/2" do
    test "kills a process group including child processes" do
      case Snakepit.ProcessKiller.setsid_executable() do
        {:ok, setsid} ->
          port =
            Port.open({:spawn_executable, setsid}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              args: ["/bin/sh", "-c", "echo $$; /bin/sleep 9999 & echo $!; wait"]
            ])

          on_exit(fn -> safe_close_port(port) end)
          [pgid, child_pid] = read_pids(port, 2, 1_000)

          assert Snakepit.ProcessKiller.process_alive?(child_pid)
          assert {:ok, ^pgid} = Snakepit.ProcessKiller.get_process_group_id(child_pid)

          assert :ok = Snakepit.ProcessKiller.kill_process_group_with_escalation(pgid, 1_000)

          assert wait_for_death(pgid, 2_000), "Process group leader #{pgid} should have died"
          assert wait_for_death(child_pid, 2_000), "Child process #{child_pid} should have died"

        {:error, _} ->
          assert true
      end
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

    test "kills only processes that match the provided run_id" do
      run_id = Snakepit.RunID.generate()
      python = python_executable()

      rogue_port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          args: ["-c", "import signal; signal.pause()"]
        ])

      ProcessLeakTracker.register_port(rogue_port)

      target_port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          args: [
            "-c",
            "import signal; signal.pause()",
            "grpc_server.py",
            "--snakepit-run-id",
            run_id
          ]
        ])

      ProcessLeakTracker.register_port(target_port)

      {:os_pid, rogue_pid} = Port.info(rogue_port, :os_pid)
      {:os_pid, target_pid} = Port.info(target_port, :os_pid)

      assert Snakepit.ProcessKiller.process_alive?(target_pid)
      assert Snakepit.ProcessKiller.process_alive?(rogue_pid)

      assert {:ok, killed} = Snakepit.ProcessKiller.kill_by_run_id(run_id)
      assert killed >= 1

      assert wait_for_death(target_pid, 5_000)
      assert Snakepit.ProcessKiller.process_alive?(rogue_pid)

      safe_close_port(rogue_port)
      safe_close_port(target_port)
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
        "import signal; signal.pause()",
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

  defp python_executable do
    System.find_executable("python3") ||
      System.find_executable("python") ||
      flunk("python executable not found on PATH")
  end

  describe "rogue cleanup filter" do
    test "ignores python processes without snakepit markers" do
      refute ProcessRegistry.cleanup_candidate?(
               "python3 other_server.py --snakepit-run-id 123",
               "abc"
             )
    end

    test "ignores commands without run markers" do
      refute ProcessRegistry.cleanup_candidate?("python grpc_server.py", "abc")
    end

    test "detects commands with different run_id" do
      assert ProcessRegistry.cleanup_candidate?(
               "python grpc_server.py --snakepit-run-id other",
               "abc"
             )
    end

    test "ignores commands with current run_id" do
      refute ProcessRegistry.cleanup_candidate?(
               "python grpc_server.py --snakepit-run-id abc",
               "abc"
             )
    end

    test "supports legacy --run-id marker" do
      assert ProcessRegistry.cleanup_candidate?(
               "python grpc_server_threaded.py --run-id old",
               "new"
             )

      refute ProcessRegistry.cleanup_candidate?(
               "python grpc_server_threaded.py --run-id new",
               "new"
             )
    end

    test "custom scripts and markers can be supplied" do
      command = "python custom_bridge.py --snakepit-run-id old"

      refute ProcessRegistry.cleanup_candidate?(command, "new")

      assert ProcessRegistry.cleanup_candidate?(command, "new",
               scripts: ["custom_bridge.py"],
               run_markers: ["--snakepit-run-id"]
             )
    end

    test "foreign, current, and stale processes behave as expected" do
      run_id = "current"
      opts = [scripts: ["grpc_server.py"], run_markers: ["--snakepit-run-id"]]

      refute ProcessRegistry.cleanup_candidate?(
               "python other_server.py --snakepit-run-id stale",
               run_id,
               opts
             )

      refute ProcessRegistry.cleanup_candidate?(
               "python grpc_server.py",
               run_id,
               opts
             )

      refute ProcessRegistry.cleanup_candidate?(
               "python grpc_server.py --snakepit-run-id current",
               run_id,
               opts
             )

      assert ProcessRegistry.cleanup_candidate?(
               "python grpc_server.py --snakepit-run-id stale",
               run_id,
               opts
             )
    end
  end
end
