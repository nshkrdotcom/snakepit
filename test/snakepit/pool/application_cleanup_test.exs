defmodule Snakepit.Pool.ApplicationCleanupTest do
  @moduledoc """
  Tests that verify ApplicationCleanup does not kill processes during normal operation.
  Uses Supertester patterns for deterministic verification.

  BUG: ApplicationCleanup.terminate runs and finds "orphaned" processes that are actually
  from the current run, then kills them. This causes "Python gRPC server process exited
  with status 0 during startup" errors.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.ProcessRegistry

  setup do
    # Ensure application is running (in case a previous test stopped it)
    case Application.ensure_all_started(:snakepit) do
      {:ok, _apps} ->
        # Wait for pool to be ready
        assert_eventually(
          fn ->
            Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok
          end,
          timeout: 30_000,
          interval: 1_000
        )

      {:error, {:already_started, :snakepit}} ->
        :ok
    end

    :ok
  end

  test "ApplicationCleanup does NOT kill processes from current BEAM run" do
    # Application is already started by setup
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Poll until workers are fully started (using Supertester pattern)
    assert_eventually(
      fn ->
        count_python_processes(beam_run_id) >= 2
      end,
      timeout: 10_000,
      interval: 100
    )

    initial_count = count_python_processes(beam_run_id)
    assert initial_count >= 2, "Expected at least 2 workers to start"

    # Monitor for stability over 2 seconds (using receive timeout pattern)
    # Take 20 samples at 100ms intervals
    stable = monitor_process_stability(beam_run_id, initial_count, samples: 20, interval: 100)

    assert stable,
           """
           ApplicationCleanup killed processes from current run!
           This is the bug causing "Python gRPC server process exited with status 0" errors.
           ApplicationCleanup.terminate must ONLY kill processes from DIFFERENT beam_run_ids!
           """
  end

  # Helper to monitor process count stability
  defp monitor_process_stability(beam_run_id, expected_count, opts) do
    samples = Keyword.get(opts, :samples, 10)
    interval = Keyword.get(opts, :interval, 100)

    results =
      for _i <- 1..samples do
        # Use receive timeout instead of Process.sleep
        receive do
        after
          interval -> :ok
        end

        count = count_python_processes(beam_run_id)
        {count, count == expected_count}
      end

    # All samples should match expected count
    all_stable = Enum.all?(results, fn {_count, stable} -> stable end)

    unless all_stable do
      counts = Enum.map(results, fn {count, _} -> count end)
      IO.puts("Process count over time: #{inspect(counts)} (expected: #{expected_count})")
    end

    all_stable
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
