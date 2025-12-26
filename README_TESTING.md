# Snakepit Testing Guide

> Updated for Snakepit v0.7.4

This guide covers the testing approach for the Snakepit project, including test organization, running tests, and understanding test output.

## Test Overview

Snakepit contains comprehensive test coverage for:
- Protocol foundation (gRPC infrastructure)
- Core variable system with SessionStore
- Type system and serialization
- Bridge server implementation
- Worker lifecycle hardening (port persistence, channel reuse, ETS/DETS protections, logging redaction)
- Python integration
- Zero-copy handle lifecycle, crash barrier policy, hermetic runtime selection, and exception translation

## Running Tests

Before running any Elixir tests make sure the local toolchain is bootstrapped and healthy:

```bash
make bootstrap          # installs Mix deps, creates .venv/.venv-py313, regenerates gRPC stubs
mix snakepit.doctor     # verifies python executable, grpc import, health probe, and grpc_port availability
```

(`mix snakepit.setup` runs the same bootstrap sequence from inside Mix if `make` is unavailable.)

### Basic Test Execution
```bash
# Run all fast tests (excludes :performance, :python_integration, :slow)
mix test

# Run tests with specific tags
mix test --exclude performance  # Default: excludes performance tests
mix test --only performance      # Run only performance tests

# Run Python-backed Elixir tests (requires make bootstrap + mix snakepit.doctor)
mix test --only python_integration

# Run slow integration suites (application restarts, OS process probes, TTL waits)
mix test --include slow
mix test --only slow

# Optional GPU coverage
# Set SNAKEPIT_GPU_TESTS=true to enable GPU-tagged suites when present.

# Run specific test files
mix test test/snakepit/bridge/session_store_test.exs
mix test test/snakepit/streaming_regression_test.exs  # gRPC streaming regression
mix test test/unit/grpc/grpc_worker_ephemeral_port_test.exs           # Worker port persistence
mix test test/snakepit/grpc/bridge_server_test.exs                    # Channel reuse & parameter validation
mix test test/unit/pool/process_registry_security_test.exs            # DETS/ETS access control
mix test test/unit/logger/redaction_test.exs                          # Log redaction summaries

# Run Python pytest suites only (auto-manages .venv, installs/updates deps, regenerates protos)
./test_python.sh
./test_python.sh -k streaming  # Any args are forwarded to pytest
# No manual venv activation needed; the script handles creation/updates.
# The Python requirements now include pytest-asyncio so coroutine-based tests (e.g., heartbeat client)
# run without extra configuration.
```

### Reliability Regression Targets (v0.7.4)

- `test/unit/grpc/grpc_worker_ephemeral_port_test.exs` – verifies workers persist negotiated ports and survive pool shutdown races.
- `test/snakepit/grpc/bridge_server_test.exs` – asserts BridgeServer reuses worker channels and surfaces invalid parameter errors.
- `test/unit/pool/process_registry_security_test.exs` – prevents direct DETS writes and confirms registry APIs enforce visibility.
- `test/unit/logger/redaction_test.exs` – exercises the redaction summaries that keep secrets out of logs.
- `test/unit/bridge/session_store_test.exs` – covers per-session and global quotas plus safe reuse of existing program slots.
- `test/snakepit/zero_copy_test.exs` – validates zero-copy handle lifecycle and fallback telemetry.
- `test/snakepit/crash_barrier_test.exs` – covers tainting and retry policy behavior.
- `test/snakepit/python_runtime_test.exs` – exercises uv-managed runtime selection and metadata.
- `test/snakepit/exception_translation_test.exs` – verifies Python errors map to `Snakepit.Error.*`.
- `test/integration/runtime_contract_test.exs` – ensures kwargs/call_type/idempotent payloads are accepted.

### Fail-fast Experiment Suites

The following suites exercise the new failure-mode experiments described in `AGENTS.md`:

- `test/integration/orphan_cleanup_stress_test.exs` – boots the pool with the Python adapter, issues load, crashes BEAM, and proves DETS + ProcessKiller remove stale workers across restarts.
- `test/performance/worker_crash_storm_test.exs` – continuously kills workers while requests stream through the mock adapter and asserts the pool size, registry stats, and OS processes recover.
- `test/unit/config/startup_fail_fast_test.exs` – verifies `Snakepit.Application` aborts early for missing executables, invalid pool profiles, and gRPC port binding conflicts.
- `test/snakepit/grpc/heartbeat_failfast_test.exs` – covers dependent vs. independent heartbeat monitors using telemetry plus `ProcessRegistry` assertions.
- `test/snakepit/streaming_regression_test.exs` – streaming cancellation regression to ensure workers are checked back into the pool and telemetry marks the request complete.
- `test/unit/pool/pool_queue_management_test.exs` – includes a runtime saturation scenario driven by `Snakepit.TestAdapters.QueueProbeAdapter` to prove queue timeouts never execute.
- `test/snakepit/multi_pool_execution_test.exs` – multi-pool isolation: broken pools stay quarantined while healthy pools keep serving.
- `test/snakepit/process_killer_test.exs` – spawns fake Python processes to validate `ProcessKiller.kill_by_run_id/1` only kills matching run IDs.

### Test Modes

The test suite runs in different modes based on tags:
- **Default**: Unit and integration tests (excludes `:performance`, `:python_integration`, and `:slow`)
- **Python Integration**: Elixir ↔ Python flows (run with `mix test --only python_integration`)
- **Performance**: Benchmarks and latency tests (use `--only performance`)
- **Slow Integration**: Full application restarts, OS process cleanup verification, queue saturation, and TTL-dependent flows. These are tagged `@tag :slow` (or `@moduletag :slow`) and run with `mix test --include slow` when you need the exhaustive coverage.

## Understanding Test Output

### Expected Warnings

Some tests intentionally trigger warnings to verify error handling. These are **expected and normal**:

1. **gRPC Server Shutdown Warning**
   ```
   ⏰ gRPC server PID XXXXX did not exit gracefully within 500ms. Forcing SIGKILL.
   ```
   This occurs during test cleanup when the gRPC server is forcefully terminated. It's expected behavior.

2. **Server Configuration**
   All gRPC server configuration warnings have been resolved in the current implementation.

### Test Statistics

A typical successful test run shows:
```
Finished in 1.9 seconds (1.1s async, 0.7s sync)
182 tests, 0 failures
```

## Test Organization

```
test/
├── unit/
│   ├── bridge/            # SessionStore quotas, ToolRegistry validation
│   ├── config/            # Mix config normalization helpers
│   ├── grpc/              # Worker port persistence, channel reuse, telemetry
│   ├── logger/            # Redaction utilities
│   ├── mix/               # Diagnose tasks and shell fallbacks
│   ├── pool/              # Supervisor lifecycle, registry hardening
│   └── worker_profile/    # Profile-specific control logic
├── snakepit/
│   ├── bridge/            # End-to-end bridge flows
│   ├── grpc/              # BridgeServer + heartbeat integration
│   ├── integration/       # Cross-language happy-paths
│   ├── pool/              # Session affinity + multipool integration
│   ├── telemetry/         # Metrics + tracing plumbing
│   └── worker_profile/    # Profile behaviour under real pools
├── performance/           # Optional perf benchmarks (:performance tag)
├── support/               # Shared helpers and fixtures
└── test_helper.exs        # Global test configuration
```

## Key Test Categories

### 1. Protocol Tests
Tests the gRPC protocol implementation including:
- Service definitions
- Message serialization
- RPC handlers

### 2. Type System Tests
Validates the type system including:
- Type validation and constraints
- Serialization/deserialization
- Special value handling (infinity, NaN)

### 3. SessionStore Tests
Tests the core state management:
- Session lifecycle
- Variable CRUD operations
- Batch operations
- TTL and cleanup

### 4. Integration Tests
End-to-end tests covering:
- Python-Elixir communication
- Full request/response cycles
- Error propagation

## Writing Tests

### Test Patterns

1. **Use descriptive test names**
   ```elixir
   test "handles special float values correctly" do
     # Test implementation
   end
   ```

2. **Group related tests with describe blocks**
   ```elixir
   describe "batch operations" do
     test "get_variables returns all found variables" do
       # Test implementation
     end
   end
   ```

3. **Capture expected logs**
   ```elixir
   {result, logs} = with_log(fn ->
     # Code that generates expected warnings
   end)
   assert logs =~ "Expected warning message"
   ```

### Performance Tests

Performance tests are tagged and excluded by default:
```elixir
@tag :performance
test "handles 1000 concurrent requests" do
  # Performance test implementation
end
```

## Continuous Integration

The test suite is designed to run in CI environments:
- All tests must pass before merging
- Performance tests are run separately
- Test coverage is monitored

## Troubleshooting

### Common Issues

1. **Port Already in Use**
   - The gRPC server uses port 50051
   - Ensure no other services are using this port

2. **Python Dependencies**
   - Some integration tests require the Python bridge packages
   - Create a virtualenv and install deps: `python3 -m venv .venv && .venv/bin/pip install -r priv/python/requirements.txt`
   - Export the interpreter for Mix so workers reuse it: `export SNAKEPIT_PYTHON="$PWD/.venv/bin/python3"`
   - Run bridge tests with the bundled modules on the path: `PYTHONPATH=priv/python .venv/bin/pytest priv/python/tests -q`
   - `make test` wraps these steps; run it when debugging cross-language failures

3. **Compilation Warnings**
   - Protocol buffer regeneration may be needed
   - Run `mix snakepit.setup` (or `mix grpc.gen` if you only need Elixir bindings)

### Telemetry Verification Checklist

- `mix test` – exercises the Elixir OpenTelemetry spans/metrics wiring (fails fast if the Python bridge cannot import OTEL SDK).
- `PYTHONPATH=priv/python .venv/bin/pytest priv/python/tests/test_telemetry.py -q` – validates the Python span helpers and correlation filter.
- `curl http://localhost:9568/metrics` – shows Prometheus metrics after enabling the reporter with `config :snakepit, telemetry_metrics: %{prometheus: %{enabled: true}}`.
- Set `SNAKEPIT_OTEL_ENDPOINT=http://collector:4318` (or `SNAKEPIT_OTEL_CONSOLE=true`) to watch trace exports when running end-to-end examples.

## Related Documentation

- [Main README](README.md) - Project overview
- [Unified gRPC Bridge (archived)](docs/archive/design-process/README_UNIFIED_GRPC_BRIDGE.md) - Historical protocol notes
- [Main README](README.md) - Implementation status
