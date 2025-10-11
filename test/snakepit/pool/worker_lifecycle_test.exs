defmodule Snakepit.Pool.WorkerLifecycleTest do
  @moduledoc """
  Tests that verify worker processes are properly cleaned up using Supertester patterns.
  These tests MUST FAIL if workers orphan their Python processes.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.ProcessRegistry

  setup do
    # Only kill truly orphaned processes, not current ones
    # This is gentler than pkill -9 which can interfere with other running tests
    :ok
  end

  test "workers clean up Python processes on normal shutdown" do
    # Application is already started by test_helper.exs
    # Get BEAM run ID
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Poll until workers are started (using Supertester pattern)
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) >= 2
      end,
      timeout: 10_000,
      interval: 100
    )

    python_processes_before = count_python_processes(beam_run_id)
    assert python_processes_before >= 2, "Expected at least 2 Python workers to start"

    # Stop all workers (not the entire application - just the pool workers)
    Supervisor.terminate_child(Snakepit.Supervisor, Snakepit.Pool)

    # Poll until ALL Python processes for these workers are gone
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) == 0
      end,
      timeout: 5_000,
      interval: 100
    )

    python_processes_after = count_python_processes(beam_run_id)

    # Restart the pool for subsequent tests
    Supervisor.restart_child(Snakepit.Supervisor, Snakepit.Pool)

    assert python_processes_after == 0,
           """
           Expected 0 Python processes after shutdown, but found #{python_processes_after}.
           Workers started: #{python_processes_before}
           Workers remaining: #{python_processes_after}

           This indicates GRPCWorker.terminate/2 was not called or failed to kill Python processes.
           """
  end

  test "ApplicationCleanup does NOT run during normal operation" do
    # Application is already started by test_helper.exs
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Poll until workers are started
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) >= 2
      end,
      timeout: 10_000,
      interval: 100
    )

    initial_count = count_python_processes(beam_run_id)

    # Monitor process count stability over time (using receive timeout pattern)
    # Take 10 samples at 200ms intervals (2 seconds total)
    samples =
      for _i <- 1..10 do
        # Use receive timeout instead of Process.sleep
        receive do
        after
          200 -> :ok
        end

        count_python_processes(beam_run_id)
      end

    # All samples should equal initial count (process count should be stable)
    stable = Enum.all?(samples, fn count -> count == initial_count end)

    unless stable do
      IO.puts("Process count over time: #{inspect(samples)} (expected: #{initial_count})")
    end

    assert stable,
           """
           Python process count changed during normal operation!
           Initial: #{initial_count}, Samples: #{inspect(samples)}

           This indicates ApplicationCleanup is incorrectly killing processes during normal operation,
           or workers are crashing and restarting.
           """
  end

  test "no orphaned processes exist - all workers tracked in registry" do
    # Application is already started by test_helper.exs
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Poll until workers are started
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) >= 2
      end,
      timeout: 10_000,
      interval: 100
    )

    # Get all Python processes and verify they're all registered
    python_pids =
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

    # Get all registered PIDs from ProcessRegistry
    registered_pids = ProcessRegistry.get_all_process_pids()

    # Every Python process should be registered
    unregistered_pids = python_pids -- registered_pids

    assert unregistered_pids == [],
           """
           Found #{length(unregistered_pids)} unregistered Python processes!
           These are orphans not tracked by ProcessRegistry.
           Unregistered PIDs: #{inspect(unregistered_pids)}
           """
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
