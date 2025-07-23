# Ensure Supertester is available
Code.ensure_loaded?(Supertester.UnifiedTestFoundation) ||
  raise "Supertester not found. Run: mix deps.get"

# Test support files are automatically compiled by Mix

# Start ExUnit with performance tests excluded by default
ExUnit.start(exclude: [:performance])
