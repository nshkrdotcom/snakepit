# Snakepit World-Class ML Implementation Prompt

## Mission

Implement all world-class ML features for Snakepit as specified in the design documents. Use TDD throughout. All tests must pass with no warnings, no errors, no Dialyzer errors, and no Credo --strict issues. Upon completion, bump version to 0.8.0.

---

## Required Reading

### Design Documents (read all before starting)

```
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/01-zero-copy-tensor-protocol.md
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/02-crash-barrier-supervision.md
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/03-hardware-abstraction-layer.md
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/04-telemetry-observability.md
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/05-structured-exception-protocol.md
/home/home/p/g/n/snakepit/docs/20251227/world-class-ml/06-implementation-roadmap.md
```

### Existing Source Files (understand current architecture)

```
# Core modules
/home/home/p/g/n/snakepit/lib/snakepit.ex
/home/home/p/g/n/snakepit/lib/snakepit/application.ex
/home/home/p/g/n/snakepit/lib/snakepit/error.ex
/home/home/p/g/n/snakepit/lib/snakepit/telemetry.ex
/home/home/p/g/n/snakepit/lib/snakepit/python_runtime.ex
/home/home/p/g/n/snakepit/lib/snakepit/bootstrap.ex

# Pool and worker management
/home/home/p/g/n/snakepit/lib/snakepit/pool/pool.ex
/home/home/p/g/n/snakepit/lib/snakepit/pool/registry.ex
/home/home/p/g/n/snakepit/lib/snakepit/pool/worker_supervisor.ex
/home/home/p/g/n/snakepit/lib/snakepit/pool/worker_starter.ex

# Error handling
/home/home/p/g/n/snakepit/lib/snakepit/error/python_exceptions.ex
/home/home/p/g/n/snakepit/lib/snakepit/error/python_translation.ex

# Worker profiles
/home/home/p/g/n/snakepit/lib/snakepit/worker_profile/process.ex
/home/home/p/g/n/snakepit/lib/snakepit/worker_profile/thread.ex

# Bridge
/home/home/p/g/n/snakepit/lib/snakepit/bridge/session.ex
/home/home/p/g/n/snakepit/lib/snakepit/bridge/session_store.ex
```

### Existing Test Files (understand test patterns)

```
/home/home/p/g/n/snakepit/test/snakepit/crash_barrier_test.exs
/home/home/p/g/n/snakepit/test/snakepit/zero_copy_test.exs
/home/home/p/g/n/snakepit/test/snakepit/python_runtime_test.exs
/home/home/p/g/n/snakepit/test/snakepit/exception_translation_test.exs
/home/home/p/g/n/snakepit/test/integration/telemetry_flow_test.exs
/home/home/p/g/n/snakepit/test/integration/runtime_contract_test.exs
```

### Configuration Files

```
/home/home/p/g/n/snakepit/mix.exs
/home/home/p/g/n/snakepit/config/config.exs
/home/home/p/g/n/snakepit/config/test.exs
/home/home/p/g/n/snakepit/.credo.exs
/home/home/p/g/n/snakepit/README.md
/home/home/p/g/n/snakepit/CHANGELOG.md
```

---

## Implementation Order (follow strictly)

### Phase 1: Hardware Abstraction Layer

**Create these files using TDD (write tests first):**

```elixir
# Tests first
test/snakepit/hardware_test.exs
test/snakepit/hardware/detector_test.exs
test/snakepit/hardware/cuda_detector_test.exs
test/snakepit/hardware/mps_detector_test.exs
test/snakepit/hardware/cpu_detector_test.exs
test/snakepit/hardware/selector_test.exs

# Then implementation
lib/snakepit/hardware.ex
lib/snakepit/hardware/detector.ex
lib/snakepit/hardware/cuda_detector.ex
lib/snakepit/hardware/mps_detector.ex
lib/snakepit/hardware/cpu_detector.ex
lib/snakepit/hardware/selector.ex
```

**Key functions to implement:**
- `Snakepit.Hardware.detect/0` - Returns complete hardware info
- `Snakepit.Hardware.capabilities/0` - Returns capability flags
- `Snakepit.Hardware.identity/0` - Returns identity map for lock files
- `Snakepit.Hardware.select/1` - Selects appropriate device

### Phase 2: Enhanced Telemetry

**Create these files using TDD:**

```elixir
# Tests first
test/snakepit/telemetry/events_test.exs
test/snakepit/telemetry/handlers/logger_test.exs
test/snakepit/telemetry/handlers/metrics_test.exs
test/snakepit/telemetry/gpu_profiler_test.exs
test/snakepit/telemetry/span_test.exs

# Then implementation
lib/snakepit/telemetry/events.ex
lib/snakepit/telemetry/handlers/logger.ex
lib/snakepit/telemetry/handlers/metrics.ex
lib/snakepit/telemetry/gpu_profiler.ex
lib/snakepit/telemetry/span.ex
```

**Update existing:**
- `lib/snakepit/telemetry.ex` - Add new event definitions
- `lib/snakepit/application.ex` - Start GPU profiler if configured

### Phase 3: Structured Exception Protocol

**Create these files using TDD:**

```elixir
# Tests first
test/snakepit/error/shape_test.exs
test/snakepit/error/device_test.exs
test/snakepit/error/parser_test.exs

# Then implementation
lib/snakepit/error/shape.ex
lib/snakepit/error/device.ex
lib/snakepit/error/parser.ex

# Python side
priv/python/snakepit/error_extractor.py
```

**Update existing:**
- `lib/snakepit/error.ex` - Add new error types and from_python/1
- `lib/snakepit/error/python_translation.ex` - Integrate with parser

### Phase 4: Crash Barrier Supervision

**Create these files using TDD:**

```elixir
# Tests first
test/snakepit/circuit_breaker_test.exs
test/snakepit/health_monitor_test.exs
test/snakepit/retry_policy_test.exs
test/snakepit/executor_test.exs

# Then implementation
lib/snakepit/circuit_breaker.ex
lib/snakepit/health_monitor.ex
lib/snakepit/retry_policy.ex
lib/snakepit/executor.ex
```

**Update existing:**
- `lib/snakepit/pool/pool.ex` - Integrate circuit breaker
- `lib/snakepit/application.ex` - Add supervision tree entries

### Phase 5: Zero-Copy Tensor Protocol

**Create these files using TDD:**

```elixir
# Tests first
test/snakepit/zero_copy/tensor_ref_test.exs
test/snakepit/zero_copy/nif_test.exs
test/snakepit/arrow_test.exs
test/snakepit/dlpack_test.exs

# Then implementation
lib/snakepit/zero_copy.ex
lib/snakepit/zero_copy/tensor_ref.ex
lib/snakepit/zero_copy/nif.ex
lib/snakepit/arrow.ex
lib/snakepit/dlpack.ex

# NIF (if implementing native)
c_src/zero_copy_nif.c
Makefile (or use elixir_make)

# Python side
priv/python/snakepit/zero_copy.py
priv/python/snakepit/arrow_bridge.py
priv/python/snakepit/dlpack_bridge.py
```

---

## Documentation Updates

### Create new guide files:

```
/home/home/p/g/n/snakepit/guides/hardware-detection.md
/home/home/p/g/n/snakepit/guides/zero-copy-tensors.md
/home/home/p/g/n/snakepit/guides/crash-recovery.md
/home/home/p/g/n/snakepit/guides/telemetry.md
/home/home/p/g/n/snakepit/guides/error-handling.md
```

### Update mix.exs docs section:

```elixir
defp docs do
  [
    main: "readme",
    extras: [
      "README.md",
      "CHANGELOG.md",
      "guides/hardware-detection.md",
      "guides/zero-copy-tensors.md",
      "guides/crash-recovery.md",
      "guides/telemetry.md",
      "guides/error-handling.md"
    ],
    groups_for_extras: [
      Guides: Path.wildcard("guides/*.md")
    ],
    groups_for_modules: [
      "Core": [Snakepit, Snakepit.Error],
      "Hardware": [Snakepit.Hardware, Snakepit.Hardware.Detector],
      "Zero-Copy": [Snakepit.ZeroCopy, Snakepit.Arrow, Snakepit.DLPack],
      "Reliability": [Snakepit.CircuitBreaker, Snakepit.HealthMonitor, Snakepit.RetryPolicy],
      "Telemetry": [Snakepit.Telemetry, Snakepit.Telemetry.GPUProfiler]
    ]
  ]
end
```

---

## Example Updates

### Create new example:

```
/home/home/p/g/n/snakepit/examples/ml_demo/
├── mix.exs
├── lib/
│   └── ml_demo.ex
├── test/
│   └── ml_demo_test.exs
└── README.md
```

The example should demonstrate:
- Hardware detection and device selection
- Zero-copy tensor passing
- Error handling with pattern matching
- Telemetry integration
- Crash recovery

---

## Quality Checks (all must pass)

```bash
# Run in /home/home/p/g/n/snakepit

# 1. All tests pass
mix test

# 2. No warnings during compilation
mix compile --warnings-as-errors

# 3. No Dialyzer errors
mix dialyzer

# 4. No Credo issues
mix credo --strict

# 5. Documentation builds
mix docs

# 6. Format check
mix format --check-formatted
```

---

## Version Bump

### Update mix.exs:

```elixir
@version "0.8.0"  # was "0.7.7"
```

### Update README.md:

Update any version references from 0.7.x to 0.8.0

### Update CHANGELOG.md:

Add entry at the top:

```markdown
## [0.8.0] - 2025-12-27

### Added
- Hardware abstraction layer with CUDA, MPS, and CPU detection
- Zero-copy tensor protocol with shared memory support
- Apache Arrow integration for columnar data interchange
- DLPack support for GPU tensor sharing
- Circuit breaker for Python worker fault tolerance
- Health monitor for crash pattern detection
- Retry policy with exponential backoff
- GPU memory profiler with telemetry
- Structured exception protocol with ML-specific errors
- Shape mismatch errors with dimension context
- Device errors with OOM recovery suggestions
- New telemetry events for all operations

### Changed
- Enhanced telemetry module with ML-specific metrics
- Improved error translation with pattern-matchable types
- Worker pool now uses circuit breaker pattern

### Fixed
- [List any bugs fixed during implementation]
```

---

## Final Verification

Before marking complete, verify:

1. [ ] All 6 design documents fully implemented
2. [ ] All new modules have comprehensive tests
3. [ ] All tests pass: `mix test`
4. [ ] No compilation warnings: `mix compile --warnings-as-errors`
5. [ ] Dialyzer clean: `mix dialyzer`
6. [ ] Credo clean: `mix credo --strict`
7. [ ] Docs build: `mix docs`
8. [ ] Format clean: `mix format --check-formatted`
9. [ ] Example runs successfully
10. [ ] Version bumped to 0.8.0
11. [ ] CHANGELOG.md updated
12. [ ] README.md updated
13. [ ] All guides written and linked in mix.exs

---

## Notes for Implementation

1. **TDD is mandatory**: Write failing tests first, then implement
2. **One phase at a time**: Complete each phase before moving to next
3. **Keep existing tests passing**: Don't break existing functionality
4. **Follow existing code style**: Match patterns in existing codebase
5. **Document public functions**: All public functions need @doc
6. **Type specs required**: All public functions need @spec
7. **Handle edge cases**: Consider nil, empty, error cases
8. **Integration tests**: Add integration tests for cross-module functionality
