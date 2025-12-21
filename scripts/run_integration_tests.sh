#!/usr/bin/env bash
# Run Snakepit integration tests with up-to-date assets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo "Running Snakepit integration test suite"
echo "=========================================="

export MIX_ENV=${MIX_ENV:-test}

echo "Step 1: Bootstrap toolchain (Mix + Python + gRPC stubs)..."
mix snakepit.setup

echo "Step 2: Verify environment (doctor)..."
mix snakepit.doctor

echo "Step 3: Run integration tests..."
mix test --only integration

echo "Step 4: Run Python-backed integration tests..."
mix test --only python_integration

if [ "${1:-}" = "--perf" ]; then
  echo "Step 5: Run performance-tagged tests..."
  mix test --only performance
fi
