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
    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Get BEAM run ID after app starts
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

    # Stop the application
    Application.stop(:snakepit)

    # Poll until ALL Python processes are gone (using Supertester pattern)
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) == 0
      end,
      timeout: 5_000,
      interval: 100
    )

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

    Application.stop(:snakepit)

    # Poll until cleanup is complete
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) == 0
      end,
      timeout: 5_000,
      interval: 100
    )
  end

  test "no orphaned processes exist after multiple start/stop cycles" do
    # Run 3 start/stop cycles
    for cycle <- 1..3 do
      {:ok, _} = Application.ensure_all_started(:snakepit)
      beam_run_id = ProcessRegistry.get_beam_run_id()

      # Poll until workers are started
      assert_eventually(
        fn ->
          count_python_processes(beam_run_id) >= 2
        end,
        timeout: 10_000,
        interval: 100
      )

      Application.stop(:snakepit)

      # Poll until all processes are cleaned up
      assert_eventually(
        fn ->
          count_python_processes(beam_run_id) == 0
        end,
        timeout: 5_000,
        interval: 100
      )

      # Check for orphans from this run
      orphans = find_orphaned_processes(beam_run_id)

      if length(orphans) > 0 do
        # Cleanup before failing
        System.cmd("pkill", ["-9", "-f", "grpc_server.py"], stderr_to_stdout: true)

        flunk("""
        Cycle #{cycle}: Found #{length(orphans)} orphaned processes after stop cycle!
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
