# Integration Tests for Unified Bridge Variable System

This directory contains comprehensive integration tests for the unified bridge variable system that verify the complete Elixir-Python communication stack.

## Overview

The integration tests validate:
- Variable lifecycle (create, read, update, delete)
- Type validation and constraints
- Batch operations
- Cache behavior
- Error scenarios
- Concurrent access
- Session isolation
- Performance benchmarks

## Running Tests

### Quick Start

```bash
# Run all integration tests
./test/run_integration_tests.sh

# Run with performance benchmarks
./test/run_integration_tests.sh --with-benchmarks

# Run specific test file
cd snakepit
PYTHONPATH="priv/python:test" python -m pytest test/integration/test_variables.py -v

# Run only benchmarks
PYTHONPATH="priv/python:test" python test/integration/test_performance.py
```

### Prerequisites

1. Elixir and Erlang installed
2. Python 3.8+ with pip
3. Required Python packages:
   ```bash
   pip install pytest pytest-asyncio grpcio grpcio-tools
   ```

## Test Structure

- `test_infrastructure.py` - Test server management and fixtures
- `test_variables.py` - Core variable operation tests
- `test_performance.py` - Performance benchmarks
- `conftest.py` - Pytest configuration

## Test Categories

### Unit Tests (Elixir)
Run with: `mix test`

These test individual components in isolation:
- Variable module
- SessionStore extensions
- Type system
- gRPC handlers

### Integration Tests (Python)
Run with: `pytest test/integration/`

These test the full stack:
- gRPC communication
- Type marshaling
- Cache behavior
- Error propagation

### Performance Benchmarks
Run with: `python test/integration/test_performance.py`

These measure:
- Operation latency
- Cache effectiveness
- Batch operation benefits
- Concurrent scalability

## Expected Performance

Based on the integration tests, the system should achieve:

1. **Single Operations**:
   - Register: < 10ms average
   - Get (cached): < 1ms average
   - Get (uncached): < 5ms average
   - Update: < 10ms average

2. **Batch Operations**:
   - 10x improvement over individual operations
   - Linear scaling up to 1000 variables

3. **Cache Performance**:
   - 90%+ hit rate for hot variables
   - 5-10x speedup for cached access

4. **Concurrent Access**:
   - Near-linear scaling up to 10 workers
   - No deadlocks or race conditions

## Troubleshooting

### Server Won't Start

1. Check port availability:
   ```bash
   lsof -i :50051
   ```

2. Ensure dependencies are installed:
   ```bash
   mix deps.get
   pip install -r requirements.txt
   ```

### Tests Fail to Connect

1. Verify gRPC server is running:
   ```bash
   ps aux | grep grpc
   ```

2. Check firewall settings for localhost connections

### Performance Issues

1. Enable debug logging:
   ```bash
   export LOG_LEVEL=debug
   ./test/run_integration_tests.sh
   ```

2. Run benchmarks in isolation:
   ```bash
   python test/integration/test_performance.py
   ```

## CI/CD Integration

The tests are configured to run in GitHub Actions. See `.github/workflows/integration_tests.yml` for the CI configuration.

## Future Enhancements

- Add chaos testing (network failures, server restarts)
- Implement load testing with larger datasets
- Add memory profiling
- Create visual performance dashboards