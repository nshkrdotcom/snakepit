# Snakepit World-Class ML Implementation Roadmap

## Overview

This document provides the implementation roadmap for achieving world-class ML support in Snakepit. All features are designed to work together and must be implemented in the specified order due to dependencies.

## Dependency Graph

```
┌─────────────────────────────────────────────────────────────────┐
│                    IMPLEMENTATION ORDER                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Phase 1: Foundation                                            │
│  ├── 1.1 Hardware Abstraction Layer (no deps)                   │
│  └── 1.2 Telemetry Infrastructure (no deps)                     │
│                                                                  │
│  Phase 2: Reliability                                           │
│  ├── 2.1 Structured Exception Protocol (needs 1.2)              │
│  └── 2.2 Crash Barrier Supervision (needs 1.1, 1.2)             │
│                                                                  │
│  Phase 3: Performance                                           │
│  └── 3.1 Zero-Copy Tensor Protocol (needs 1.1, 1.2, 2.1)        │
│                                                                  │
│  Phase 4: Polish                                                │
│  ├── 4.1 GPU Memory Profiler (needs 1.1, 1.2, 3.1)              │
│  ├── 4.2 LiveDashboard Integration (needs 1.2, 2.2)             │
│  └── 4.3 Documentation & Benchmarks                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Phase 1: Foundation (Weeks 1-2)

### 1.1 Hardware Abstraction Layer

**Document**: `03-hardware-abstraction-layer.md`

**Timeline**: Week 1

**Deliverables**:
- [ ] `Snakepit.Hardware` module
- [ ] CUDA detector (nvidia-smi parsing)
- [ ] MPS detector (Apple Silicon)
- [ ] CPU feature detector
- [ ] Device selector with fallback
- [ ] Hardware identity for lock files

**Files to create**:
```
lib/snakepit/hardware.ex
lib/snakepit/hardware/detector.ex
lib/snakepit/hardware/cuda_detector.ex
lib/snakepit/hardware/mps_detector.ex
lib/snakepit/hardware/cpu_detector.ex
lib/snakepit/hardware/selector.ex
test/snakepit/hardware_test.exs
```

**Acceptance criteria**:
- `Snakepit.Hardware.detect/0` returns complete hardware info
- `Snakepit.Hardware.capabilities/0` returns capability flags
- `Snakepit.Hardware.select/1` selects appropriate device
- Tests pass on Linux (CUDA), macOS (MPS), and CPU-only environments

### 1.2 Telemetry Infrastructure

**Document**: `04-telemetry-observability.md`

**Timeline**: Week 1-2

**Deliverables**:
- [ ] `Snakepit.Telemetry` event definitions
- [ ] Logger handler (default)
- [ ] Metrics handler (Prometheus-compatible)
- [ ] Execution path instrumentation
- [ ] Worker pool instrumentation

**Files to create**:
```
lib/snakepit/telemetry.ex
lib/snakepit/telemetry/events.ex
lib/snakepit/telemetry/handlers/logger.ex
lib/snakepit/telemetry/handlers/metrics.ex
lib/snakepit/telemetry/span.ex
test/snakepit/telemetry_test.exs
```

**Acceptance criteria**:
- All core events documented and emitted
- Logger handler logs at appropriate levels
- Metrics definitions work with TelemetryMetrics
- <1% overhead when enabled

## Phase 2: Reliability (Weeks 3-4)

### 2.1 Structured Exception Protocol

**Document**: `05-structured-exception-protocol.md`

**Timeline**: Week 3

**Deliverables**:
- [ ] Error type hierarchy
- [ ] Python error extraction (Python side)
- [ ] Error parsing (Elixir side)
- [ ] Shape error handling
- [ ] Device/OOM error handling
- [ ] Suggestion generation

**Files to create**:
```
lib/snakepit/error.ex
lib/snakepit/error/shape.ex
lib/snakepit/error/device.ex
lib/snakepit/error/parser.ex
python/snakepit/error_extractor.py
test/snakepit/error_test.exs
```

**Acceptance criteria**:
- Pattern matching works on all error types
- Shape errors include dimensions and suggestions
- OOM errors include memory info
- Python tracebacks preserved

**Dependencies**: 1.2 (Telemetry for error events)

### 2.2 Crash Barrier Supervision

**Document**: `02-crash-barrier-supervision.md`

**Timeline**: Week 3-4

**Deliverables**:
- [ ] Port-based worker isolation
- [ ] Exit status classification
- [ ] Worker restart logic
- [ ] Circuit breaker
- [ ] Health monitor
- [ ] Retry policy

**Files to create**:
```
lib/snakepit/worker.ex (modify)
lib/snakepit/circuit_breaker.ex
lib/snakepit/health_monitor.ex
lib/snakepit/retry_policy.ex
lib/snakepit/executor.ex
test/snakepit/crash_barrier_test.exs
```

**Acceptance criteria**:
- Python segfault doesn't crash BEAM
- Workers restart after crash
- Circuit breaker opens after repeated failures
- Idempotent operations retry automatically
- Crash patterns are logged

**Dependencies**: 1.1 (Hardware for device affinity), 1.2 (Telemetry for events)

## Phase 3: Performance (Weeks 5-7)

### 3.1 Zero-Copy Tensor Protocol

**Document**: `01-zero-copy-tensor-protocol.md`

**Timeline**: Weeks 5-7

**Deliverables**:
- [ ] NIF for shared memory (POSIX shm)
- [ ] `Snakepit.ZeroCopy` module
- [ ] Python bridge (NumPy arrays)
- [ ] Arrow IPC support
- [ ] GPU tensor references (CUDA IPC)
- [ ] Auto-detection for large data

**Files to create**:
```
c_src/zero_copy_nif.c
lib/snakepit/zero_copy.ex
lib/snakepit/zero_copy/nif.ex
lib/snakepit/zero_copy/tensor_ref.ex
lib/snakepit/arrow.ex
lib/snakepit/dlpack.ex
python/snakepit/zero_copy.py
python/snakepit/arrow_bridge.py
python/snakepit/dlpack_bridge.py
test/snakepit/zero_copy_test.exs
```

**Acceptance criteria**:
- 1MB array transfer < 1ms (was ~50ms with JSON)
- 100MB array transfer < 10ms
- GPU tensors transfer via IPC handle
- Round-trip preserves data exactly
- Memory properly cleaned up

**Dependencies**: 1.1 (Hardware for GPU detection), 1.2 (Telemetry), 2.1 (Errors)

## Phase 4: Polish (Week 8)

### 4.1 GPU Memory Profiler

**Timeline**: Week 8 (part 1)

**Deliverables**:
- [ ] `Snakepit.Telemetry.GPUProfiler` GenServer
- [ ] Periodic sampling
- [ ] History storage
- [ ] Memory events

**Files to create**:
```
lib/snakepit/telemetry/gpu_profiler.ex
test/snakepit/gpu_profiler_test.exs
```

**Dependencies**: 1.1, 1.2, 3.1

### 4.2 LiveDashboard Integration

**Timeline**: Week 8 (part 2)

**Deliverables**:
- [ ] LiveDashboard page module
- [ ] Real-time stats
- [ ] GPU memory chart
- [ ] Recent calls table

**Files to create**:
```
lib/snakepit/telemetry/live_dashboard.ex
```

**Dependencies**: 1.2, 2.2

### 4.3 Documentation & Benchmarks

**Timeline**: Week 8 (part 3)

**Deliverables**:
- [ ] API documentation
- [ ] Performance benchmarks
- [ ] Benchmark scripts
- [ ] Usage guides

**Files to create**:
```
benchmarks/zero_copy_bench.exs
benchmarks/crash_recovery_bench.exs
guides/getting-started.md
guides/zero-copy.md
guides/crash-barrier.md
```

## Configuration Summary

After implementation, Snakepit will support:

```elixir
config :snakepit,
  # Hardware
  hardware: [
    prefer: [:cuda, :mps, :cpu],
    cuda_visible_devices: nil,
    detect_on_startup: true
  ],

  # Crash Barrier
  crash_barrier: [
    enabled: true,
    worker_max_crashes: 10,
    circuit_failure_threshold: 5,
    retry_max_attempts: 3
  ],

  # Zero-Copy
  zero_copy: [
    enabled: true,
    threshold_bytes: 1_000_000,
    gpu_enabled: true,
    arrow_enabled: true
  ],

  # Telemetry
  telemetry: [
    enabled: true,
    handlers: [:logger, :metrics],
    gpu_profiler_enabled: true,
    slow_call_threshold_ms: 1000
  ],

  # Errors
  errors: [
    show_python_traceback: true,
    show_suggestions: true,
    generate_repro: true
  ]
```

## Testing Strategy

### Unit Tests
- Each module has corresponding test file
- Mock Python interactions where possible
- Test error cases thoroughly

### Integration Tests
- End-to-end tests with real Python
- GPU tests (skip on CPU-only CI)
- Crash recovery tests

### Performance Tests
- Benchmark suite for zero-copy
- Latency benchmarks
- Memory benchmarks

### CI Matrix
```yaml
test:
  strategy:
    matrix:
      os: [ubuntu-latest, macos-latest]
      elixir: ["1.15", "1.16", "1.17"]
      otp: ["25", "26", "27"]
      python: ["3.10", "3.11", "3.12"]
  env:
    CUDA_AVAILABLE: ${{ matrix.os == 'ubuntu-latest' }}
```

## Risk Mitigation

### NIF Stability
- Extensive testing of shared memory NIF
- Resource cleanup in destructors
- Fuzzing with random inputs

### GPU Compatibility
- Test on multiple CUDA versions
- Graceful fallback to CPU
- Clear error messages for GPU issues

### Memory Leaks
- Reference counting verification
- Leak detection in tests
- Finalizer coverage

## Success Metrics

### Performance
- Zero-copy: 500x improvement for large arrays
- Crash recovery: <100ms to new worker
- Overhead: <1% for instrumentation

### Reliability
- No BEAM crashes from Python failures
- 99.9% uptime with circuit breakers
- Automatic recovery for transient failures

### Developer Experience
- Pattern-matchable errors
- Actionable suggestions
- Comprehensive telemetry

## Post-Implementation

After completing Snakepit world-class ML features:

1. **Update SnakeBridge** to use new features (see SnakeBridge roadmap)
2. **Write migration guide** for existing users
3. **Publish blog post** on zero-copy performance
4. **Submit to conferences** (ElixirConf, PyData)

## Version Planning

| Version | Features |
|---------|----------|
| 0.6.0 | Hardware abstraction, Telemetry infrastructure |
| 0.7.0 | Structured exceptions, Crash barriers |
| 0.8.0 | Zero-copy tensors (CPU) |
| 0.9.0 | Zero-copy GPU, Arrow support |
| 1.0.0 | Full world-class ML support |

## Coordination with SnakeBridge

SnakeBridge depends on these Snakepit features:

| Snakepit Feature | SnakeBridge Usage |
|-----------------|-------------------|
| Hardware.identity() | Lock file hardware section |
| Error types | ML error translation |
| Telemetry events | Forward in generated wrappers |
| ZeroCopy.TensorRef | Type encoding for large data |

**Integration points**:
1. SnakeBridge calls `Snakepit.Hardware.identity()` for lock files
2. Generated wrappers catch and translate `Snakepit.Error.*`
3. Telemetry events include SnakeBridge context
4. Type encoder handles `TensorRef` specially

See: `/home/home/p/g/n/snakebridge/docs/20251227/world-class-ml/` for SnakeBridge integration details.
