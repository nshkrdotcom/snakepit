defmodule Snakepit.Pool.ApplicationCleanupTest do
  @moduledoc """
  Tests that verify ApplicationCleanup does not kill processes during normal operation.

  BUG: ApplicationCleanup.terminate runs and finds "orphaned" processes that are actually
  from the current run, then kills them. This causes "Python gRPC server process exited
  with status 0 during startup" errors.
  """
  use ExUnit.Case, async: false

  alias Snakepit.Pool.ProcessRegistry

  test "ApplicationCleanup does NOT kill processes from current BEAM run" do
    # Start app
    {:ok, _} = Application.ensure_all_started(:snakepit)
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Wait for workers to fully start
    Process.sleep(1000)

    # Count Python processes
    initial_count = count_python_processes(beam_run_id)
    assert initial_count >= 2, "Expected at least 2 workers to start"

    # Run for a while - ApplicationCleanup should NOT kill anything
    Process.sleep(2000)

    # Verify count unchanged
    current_count = count_python_processes(beam_run_id)

    assert current_count == initial_count,
           """
           ApplicationCleanup killed processes from current run!
           Initial: #{initial_count}, After 2s: #{current_count}

           This is the bug causing "Python gRPC server process exited with status 0" errors.
           ApplicationCleanup.terminate must ONLY kill processes from DIFFERENT beam_run_ids!
           """

    # Cleanup
    Application.stop(:snakepit)
    Process.sleep(2000)
  end

  defp count_python_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true
         ) do
      {"", 1} -> 0
      {output, 0} -> output |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end
end
