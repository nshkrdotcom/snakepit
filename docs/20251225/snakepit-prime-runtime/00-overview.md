# 00 - Overview

## Goal

Make Snakepit a credible, production-grade runtime for ML workloads without changing SnakeBridge's compile-time responsibilities.

## Constraints

- Snakepit remains the runtime substrate.
- SnakeBridge remains compile-time codegen.
- No mid-compilation injection.
- Source caching stays in SnakeBridge.
- Runtime changes must be safe for BEAM and observable.

## New Runtime Capabilities

### 1) Zero-Copy Interop

- DLPack for tensor interchange (Nx <-> PyTorch/JAX/CuPy/NumPy).
- Arrow for columnar data interchange (Elixir table <-> Pandas/Polars/PyArrow).
- Explicit ownership rules and best-effort fallback when zero-copy is not possible.

### 2) Crash Barrier

- Classify worker crashes (segfault, CUDA fatal, OOM).
- Taint crashing workers/devices.
- Optional retry for idempotent calls.
- Return structured `:worker_crash` errors when retries are disabled or exhausted.

### 3) Structured Exception Translation

- Python exceptions map to Elixir structs (ValueError, KeyError, etc).
- Metadata-driven mapping is versioned.
- Unknown exceptions fall back to `Snakepit.Error.PythonException` with full traceback.

### 4) Hermetic Python Runtime

- `uv python install` for managed interpreter.
- Interpreter hash recorded in `snakebridge.lock`.
- CI and prod do not depend on system Python.

## Why These Are Must-Have

- **Performance**: zero-copy eliminates serialization cost.
- **Stability**: crash isolation prevents VM instability.
- **Ergonomics**: structured errors are pattern-matchable.
- **Reproducibility**: hermetic runtime kills "works on my machine".

## Success Criteria

- Large tensor transfers are zero-copy by default where supported.
- Python crashes do not affect BEAM availability.
- Exception types are pattern-matchable in Elixir.
- Managed Python runtime works in CI without system Python.

