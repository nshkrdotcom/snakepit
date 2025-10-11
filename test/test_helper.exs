# Ensure Supertester is available
Code.ensure_loaded?(Supertester.UnifiedTestFoundation) ||
  raise "Supertester not found. Run: mix deps.get"

# Test support files are automatically compiled by Mix

# Helper for polling worker shutdown
defmodule TestHelperShutdown do
  def wait_for_worker_shutdown(beam_run_id, deadline) do
    current = System.monotonic_time(:millisecond)

    if current >= deadline do
      # Timeout - log warning but don't fail
      IO.puts(:stderr, "Warning: Workers did not shut down within timeout")
      :ok
    else
      case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
             stderr_to_stdout: true
           ) do
        {"", 1} ->
          # All workers shut down
          :ok

        _ ->
          # Still workers running, wait and check again using receive timeout
          receive do
          after
            100 -> :ok
          end

          wait_for_worker_shutdown(beam_run_id, deadline)
      end
    end
  end
end

# Ensure proper application shutdown after all tests complete
# This allows workers to gracefully terminate Python processes
ExUnit.after_suite(fn _results ->
  # Get beam_run_id BEFORE stopping application
  beam_run_id =
    try do
      Snakepit.Pool.ProcessRegistry.get_beam_run_id()
    catch
      _, _ -> nil
    end

  # Stop the Snakepit application to trigger supervision tree shutdown
  Application.stop(:snakepit)

  # Poll until workers shut down gracefully (using receive timeout pattern)
  if beam_run_id do
    deadline = System.monotonic_time(:millisecond) + 5_000
    TestHelperShutdown.wait_for_worker_shutdown(beam_run_id, deadline)
  end

  :ok
end)

# Start ExUnit with performance tests excluded by default
ExUnit.start(exclude: [:performance])
