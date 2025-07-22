#!/bin/bash
# Run integration tests for the unified bridge variable system

set -e

echo "=== Running Variable System Integration Tests ==="

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Check if running in CI or local environment
if [ -n "$CI" ]; then
    echo "Running in CI environment"
else
    echo "Running in local environment"
fi

# Build the Elixir server
echo ""
echo "Building Elixir server..."
mix deps.get
mix compile

# Install Python test dependencies if needed
echo ""
echo "Installing Python test dependencies..."
cd "$PROJECT_ROOT/priv/python"
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate || true

# Install test dependencies
pip install pytest pytest-asyncio grpcio grpcio-tools

# Go back to project root
cd "$PROJECT_ROOT"

# Run integration tests
echo ""
echo "Running integration tests..."
PYTHONPATH="$PROJECT_ROOT/priv/python:$PROJECT_ROOT/test" python -m pytest test/integration/test_variables.py -v --tb=short

# Run benchmarks if requested
if [ "$1" == "--with-benchmarks" ] || [ "$RUN_BENCHMARKS" == "true" ]; then
    echo ""
    echo "Running performance benchmarks..."
    PYTHONPATH="$PROJECT_ROOT/priv/python:$PROJECT_ROOT/test" python test/integration/test_performance.py
fi

echo ""
echo "=== All tests completed ==="

# Check if we should generate a report
if [ -f "benchmark_results.json" ]; then
    echo ""
    echo "Benchmark results saved to benchmark_results.json"
fi

if [ -f "variable_benchmarks.png" ]; then
    echo "Benchmark plots saved to variable_benchmarks.png"
fi