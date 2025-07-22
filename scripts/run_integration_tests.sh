#!/bin/bash
# File: scripts/run_integration_tests.sh

echo "Running DSPex gRPC Bridge Integration Tests"
echo "=========================================="

# Ensure Python dependencies are installed
echo "Installing Python dependencies..."
cd snakepit/priv/python
pip install -r requirements.txt
cd ../../..

# Compile protocol buffers
echo "Compiling protocol buffers..."
cd snakepit
mix protobuf.compile
cd ..

# Run tests
echo "Running integration tests..."
cd snakepit
mix test --only integration

# Run performance tests if requested
if [ "$1" == "--perf" ]; then
  echo "Running performance tests..."
  mix test --only performance
fi