# Ensure Supertester is available
Code.ensure_loaded?(Supertester.UnifiedTestFoundation) ||
  raise "Supertester not found. Run: mix deps.get"

# Test support files are automatically compiled by Mix

# Ensure proper application shutdown after all tests complete
# This allows workers to gracefully terminate Python processes
ExUnit.after_suite(fn _results ->
  # Stop the Snakepit application to trigger supervision tree shutdown
  Application.stop(:snakepit)

  # Give workers time to shut down gracefully
  Process.sleep(2000)

  :ok
end)

# Start ExUnit with performance tests excluded by default
ExUnit.start(exclude: [:performance])
