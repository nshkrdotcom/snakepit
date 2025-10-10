defmodule Snakepit.Pool.WorkerLifecycleTest do
  @moduledoc """
  Tests that verify worker processes are properly cleaned up.
  These tests MUST FAIL if workers orphan their Python processes.
  """
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry

  setup do
    # Start with clean slate - kill any orphaned processes
    System.cmd("pkill", ["-9", "-f", "grpc_server.py"], stderr_to_stdout: true)
    Process.sleep(100)

    :ok
  end

  test "workers clean up Python processes on normal shutdown" do
    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Get BEAM run ID after app starts
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Give workers time to start
    Process.sleep(500)

    # Verify workers started
    python_processes_before = count_python_processes(beam_run_id)
    assert python_processes_before >= 2, "Expected at least 2 Python workers to start"

    # Stop the application
    Application.stop(:snakepit)

    # Give supervision tree time to shut down workers gracefully
    Process.sleep(3000)

    # Verify ALL Python processes are gone
    python_processes_after = count_python_processes(beam_run_id)

    assert python_processes_after == 0,
           """
           Expected 0 Python processes after shutdown, but found #{python_processes_after}.
           Workers started: #{python_processes_before}
           Workers remaining: #{python_processes_after}

           This indicates GRPCWorker.terminate/2 was not called or failed to kill Python processes.
           """
  end

  test "ApplicationCleanup does NOT run during normal operation" do
    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Give workers time to start
    Process.sleep(500)

    initial_count = count_python_processes(beam_run_id)

    # Run for a bit
    Process.sleep(1000)

    # ApplicationCleanup should NOT have killed anything during normal operation
    current_count = count_python_processes(beam_run_id)

    assert current_count == initial_count,
           """
           Python process count changed during normal operation!
           Initial: #{initial_count}, Current: #{current_count}

           This indicates ApplicationCleanup is incorrectly killing processes during normal operation,
           or workers are crashing and restarting.
           """

    Application.stop(:snakepit)
    Process.sleep(2000)
  end

  test "no orphaned processes exist after multiple start/stop cycles" do
    # Run 3 start/stop cycles
    for _i <- 1..3 do
      {:ok, _} = Application.ensure_all_started(:snakepit)
      beam_run_id = ProcessRegistry.get_beam_run_id()

      Process.sleep(500)

      Application.stop(:snakepit)
      Process.sleep(2000)

      # Check for orphans from this run
      orphans = find_orphaned_processes(beam_run_id)

      if length(orphans) > 0 do
        System.cmd("pkill", ["-9", "-f", "grpc_server.py"], stderr_to_stdout: true)

        flunk("""
        Found #{length(orphans)} orphaned processes after stop cycle!
        BEAM run ID: #{beam_run_id}
        Orphaned PIDs: #{inspect(orphans)}
        """)
      end
    end
  end

  # Helper functions

  defp count_python_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true
         ) do
      {"", 1} -> 0
      {output, 0} -> output |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp find_orphaned_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true
         ) do
      {"", 1} ->
        []

      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn pid_str ->
          case Integer.parse(pid_str) do
            {pid, ""} -> pid
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end
end
