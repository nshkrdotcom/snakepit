# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.7] - 2025-12-31

### Fixed
- **Python Any encoding performance** - Avoided extra UTF-8 decode/encode round-trips in `TypeSerializer`
  - JSON payloads now stay as bytes for `google.protobuf.Any.value`
  - Stabilizes orjson benchmark expectations on large payloads
- **Test isolation** - Prevented telemetry/logging state bleed across tests
  - OOM telemetry assertions now scoped by operation ID
  - Logging tests reset global logging disable state
- **Python integration test bootstrap** - Ensure `--include python_integration` reliably provisions deps
  - CLI tag detection now triggers bootstrap and real env doctor checks
  - Test helper validates `.venv` exists after bootstrap and skips redundant deps fetches
- **HealthMonitor cleanup** - Ignore benign shutdown races in test teardown
- **Ready file race condition on CI** - Fixed flaky gRPC server startup on slow/loaded systems
  - `read_ready_file/1` now returns `:not_ready` instead of error when file is empty
  - Polling loop continues retrying instead of failing immediately
  - Resolves `{:invalid_ready_file, ""}` errors on GitHub Actions runners
  - Python already uses atomic rename (`os.replace`), but edge cases on slow filesystems could still produce empty reads

## [0.8.6] - 2025-12-31

### Added
- **Session cleanup telemetry** - Emit telemetry events for session lifecycle monitoring
  - `[:snakepit, :bridge, :session, :pruned]` - Emitted when sessions expire via TTL
  - `[:snakepit, :bridge, :session, :accumulation_warning]` - Emitted when session count exceeds thresholds

- **Strict mode for session store** - New `strict_mode: true` option for dev/test environments
  - Logs loud warnings when session count exceeds 80% of `max_sessions`
  - Helps detect session leaks during development

- **BaseAdapter session context** - Added `session_id` property and `set_session_context()` to `BaseAdapter`
  - Ensures consistent session_id handling across all adapters
  - Backward compatible with existing adapter implementations

- **Session Scoping Guide** - New documentation at `guides/session-scoping-rules.md`
  - Explains session lifecycle, reference scoping, and recommended patterns
  - Documents telemetry events and strict mode configuration

## [0.8.5] - 2025-12-31

### Fixed
- **GRPCWorker graceful shutdown** - Eliminated spurious crash logs during application shutdown
  - Added `shutting_down` flag to distinguish expected exits from unexpected crashes
  - Handle supervisor EXIT signals (`:shutdown`, `{:shutdown, _}`) explicitly
  - Detect shutdown via mailbox peek and pool liveness checks to handle message race conditions
  - Shutdown exit codes (0, 137/SIGKILL, 143/SIGTERM) logged at debug level during shutdown
  - Non-zero exits only logged as errors when not in shutdown context

- **Configurable shutdown timeouts** - Graceful shutdown timeout now configurable via `:graceful_shutdown_timeout_ms`
  - Default increased from 2s to 6s to accommodate Python's async shutdown envelope
  - `child_spec` and `Worker.Starter` derive supervisor shutdown timeout from this config
  - New `Snakepit.GRPCWorker.supervisor_shutdown_timeout/0` for custom supervision trees

- **Python server shutdown** - Improved graceful termination sequence
  - Server stop grace period increased to 2 seconds
  - `wait_for_termination` now awaited with 3s timeout before force-cancel
  - Sequential shutdown: close servicer → stop server → await termination task

- **Python dependency version mismatch** - Updated `requirements.txt` to match generated protobuf/grpc stubs
  - `grpcio`: `>=1.60.0` → `>=1.76.0`
  - `protobuf`: `>=4.25.0` → `>=6.31.1`
  - Previously, users installing minimum versions would get runtime import errors

- **Proto README documentation drift** - Rewrote `priv/proto/README.md` to match actual implementation
  - Fixed service name: `SnakepitBridge` → `BridgeService`
  - Removed non-existent methods (GetVariable, SetVariable, WatchVariables, optimization APIs)
  - Documented only implemented RPC methods
  - Added `Any` encoding convention documentation
  - Clarified binary payload format (opaque bytes, not pickle/ETF specific)
  - Moved aspirational features to "Roadmap" section

- **Streaming backpressure** - Added bounded queue (maxsize=100) to `ExecuteStreamingTool`
  - Prevents unbounded memory growth when producer outpaces consumer
  - `drain_sync` now blocks on enqueue with proper exception handling

- **Streaming cancellation handling** - Producer now stops when client disconnects
  - Added cancellation event propagation to drain loops
  - Added disconnect watcher task that polls `context.is_active()`
  - Producer task explicitly cancelled on cleanup
  - Iterator/generator properly closed via `aclose()`/`close()`

- **Adapter lifecycle cleanup** - Added `cleanup()` calls to adapter lifecycle
  - `ExecuteTool`: Calls `adapter.cleanup()` in finally block (always runs)
  - `ExecuteStreamingTool`: Calls `adapter.cleanup()` in finally block
  - Uses `inspect.isawaitable()` pattern for robust sync/async handling
  - Added `_maybe_cleanup()` and `_close_iterator()` helper functions

- **Threaded server parity** - Applied all streaming/cleanup fixes to `grpc_server_threaded.py`
  - Bounded queue, cancellation handling, iterator closing, adapter cleanup

- **CancelledError handling** - Producer now properly re-raises `CancelledError`
  - Prevents task from blocking on `queue.put()` when consumer is gone
  - On cancellation, task terminates immediately without sentinel (consumer is already gone)

- **Sentinel delivery under backpressure** - Fixed potential hang when queue is full
  - Sentinel is now `await queue.put(sentinel)` (guaranteed delivery) on normal completion
  - Previous `put_nowait` could silently drop sentinel, causing consumer to hang forever

- **Sentinel delivery on disconnect** - Fixed hang when `watch_disconnect()` sets cancelled flag
  - `watch_disconnect()` now injects sentinel directly into queue when disconnect detected
  - Drops buffered chunks if needed to make room for sentinel (consumer is gone anyway)
  - Prevents hang when producer exits normally (not via CancelledError) with cancelled flag set

- **Binary parameters handling** - Fixed unconditional `pickle.loads` security issue
  - `binary_parameters` now treated as opaque bytes by default (per proto docs)
  - Pickle only used if `metadata["binary_format:<param>"] == "pickle"`
  - Enables safe handling of images, audio, and other binary data

- **Loadtest demo formatting** - Fixed `format_number/1` crash on nil values and spacing in output

### Added
- **CI version guard** - New `scripts/check_stub_versions.py` validates that `requirements.txt` versions match generated protobuf/grpc stubs
  - Integrated into GitHub Actions CI workflow
  - Checks protobuf, grpcio, and grpcio-tools versions
  - Prevents "works for us, breaks for users" dependency issues

- **Streaming cancellation tests** - New tests for streaming cleanup behavior
  - `test_streaming_cleanup_called_on_normal_completion`
  - `test_streaming_producer_stops_on_client_disconnect`
  - `test_async_streaming_cleanup_called`
  - `test_streaming_completes_under_backpressure` - verifies sentinel delivery with >maxsize chunks

### Changed
- **Adapter lifecycle documentation** - Clarified per-request adapter lifecycle in `base_adapter.py`
  - Documented that adapters are instantiated per-request
  - Added example showing module-level caching pattern for expensive resources
  - Explained `initialize()`/`cleanup()` semantics

- **Streaming demo modernization** - Updated `execute_streaming_tool_demo.exs` to use standard bootstrap pattern

## [0.8.4] - 2025-12-30

### Added
- **ExecuteStreamingTool Implementation** - Full gRPC streaming support in BridgeServer
  - End-to-end streaming from clients through to Python workers
  - Automatic final chunk injection if worker doesn't send one
  - Execution time metadata on final chunks
  - Proper error handling for streaming failures

### Fixed
- **Timeout Parsing Bug** - Fixed precedence issue in `tool_call_options/1` that caused string timeout values to bypass parsing
- **Binary Parameter Encoding** - Fixed remote tool execution to properly handle binary parameters without attempting JSON encoding of tuples

## [0.8.3] - 2025-12-29

### Fixed
- **Hardware Detector Cache** - Replaced ETS cache creation with `:persistent_term` to eliminate race conditions and table ownership hazards under concurrent access.

### Removed
- **Deprecated/Unused APIs** - Removed `RetryPolicy.exponential_backoff/2`, `RetryPolicy.with_circuit_breaker/2`, `HeartbeatMonitor.get_status/1`, `RunID.valid?/1`, and deprecated `ProcessRegistry.register_worker/4`.

## [0.8.2] - 2025-12-29

### Added
- **Process-Level Log Isolation** - New `Snakepit.Logger` functions for per-process log level control
  - `set_process_level/1` - Set log level for current process only
  - `get_process_level/0` - Get effective log level for current process
  - `clear_process_level/0` - Clear process-level override
  - `with_level/2` - Execute function with temporary log level
- **Test Helper Module** - `Snakepit.Logger.TestHelper` for test isolation
  - `setup_log_isolation/0` - Set up per-test log level isolation
  - `capture_at_level/2` - Capture logs at specific level without affecting other tests
  - `capture_at_level_with_result/2` - Capture logs and return function result
  - `suppress_logs/1` - Suppress all logs for duration of function

### Fixed
- **Flaky Test Race Condition** - Tests that modify log levels no longer interfere with each other when running concurrently
  - Root cause: Multiple async tests modifying global `Application.get_env(:snakepit, :log_level)` caused race conditions
  - Solution: Logger now checks process-local override first, then Elixir Logger process level, then global config

### Changed
- Log level resolution now uses priority order:
  1. Process-level override (via `set_process_level/1`) - highest priority
  2. Elixir Logger process level (via `Logger.put_process_level/2`)
  3. Application config (via `config :snakepit, log_level: ...`) - lowest priority

## [0.8.1] - 2025-12-27

### Changed
- **BREAKING**: Default log level changed from `:warning` to `:error` for silent-by-default behavior
- Centralized all logging through `Snakepit.Logger` module
- Python logging now respects `SNAKEPIT_LOG_LEVEL` environment variable
- Replaced stdout `GRPC_READY` signaling with a non-console control channel
- Removed all hardcoded `IO.puts` and Python `print()` statements

### Added
- Category-based logging: `:lifecycle`, `:pool`, `:grpc`, `:bridge`, `:worker`, `:startup`, `:shutdown`, `:telemetry`, `:general`
- `config :snakepit, log_categories: [...]` to enable specific categories
- `priv/python/snakepit_bridge/logging_config.py` for centralized Python logging

### Fixed
- Noisy startup messages no longer pollute console output
- Health-check messages suppressed by default
- gRPC server startup messages suppressed by default

### Migration Guide
If you relied on seeing startup logs, add to your config:
```elixir
config :snakepit, log_level: :info
```

## [0.8.0] - 2025-12-27

### Added

#### Hardware Abstraction Layer
- **Hardware Detection** - New `Snakepit.Hardware` module providing automatic detection of CPU, NVIDIA CUDA, Apple MPS, and AMD ROCm accelerators.
- **Hardware Detector** - `Snakepit.Hardware.Detector` with unified detection API and caching.
- **CPU Detection** - `Snakepit.Hardware.CPUDetector` with cores, threads, model, and feature detection (AVX, AVX2, SSE4.2).
- **CUDA Detection** - `Snakepit.Hardware.CUDADetector` for NVIDIA GPUs via nvidia-smi with version, driver, and memory info.
- **MPS Detection** - `Snakepit.Hardware.MPSDetector` for Apple Metal Performance Shaders on macOS.
- **ROCm Detection** - `Snakepit.Hardware.ROCmDetector` for AMD GPUs via rocm-smi.
- **Device Selection** - `Snakepit.Hardware.Selector` with automatic selection and fallback strategies.

#### Enhanced ML Telemetry
- **Telemetry Events** - `Snakepit.Telemetry.Events` defining ML-specific telemetry events for hardware, errors, circuit breaker, and GPU profiling.
- **Logger Handler** - `Snakepit.Telemetry.Handlers.Logger` for automatic logging of all ML telemetry events.
- **Metrics Handler** - `Snakepit.Telemetry.Handlers.Metrics` with Prometheus-compatible metric definitions.
- **GPU Profiler** - `Snakepit.Telemetry.GPUProfiler` GenServer for periodic GPU memory, utilization, temperature, and power sampling.
- **Span Helper** - `Snakepit.Telemetry.Span` for convenient timing of operations with automatic start/stop telemetry.

#### Structured Exception Protocol
- **Shape Errors** - `Snakepit.Error.Shape` with `ShapeMismatch` and `DTypeMismatch` exceptions with dimension detection.
- **Device Errors** - `Snakepit.Error.Device` with `DeviceMismatch` and `OutOfMemory` exceptions with recovery suggestions.
- **Error Parser** - `Snakepit.Error.Parser` for automatic parsing of Python errors with pattern detection for shape, device, and OOM errors.

#### Crash Barrier Supervision
- **Circuit Breaker** - `Snakepit.CircuitBreaker` GenServer with closed/open/half-open states for fault tolerance.
- **Health Monitor** - `Snakepit.HealthMonitor` for tracking crash patterns with rolling windows and health status.
- **Retry Policy** - `Snakepit.RetryPolicy` with configurable exponential backoff, jitter, and retriable error filtering.
- **Executor** - `Snakepit.Executor` with `execute_with_retry/2`, `execute_with_timeout/2`, `execute_with_circuit_breaker/3`, and batch execution.

#### Documentation
- New guide: `guides/hardware-detection.md` - Hardware detection usage and device selection.
- New guide: `guides/crash-recovery.md` - Circuit breaker, health monitoring, and retry patterns.
- New guide: `guides/error-handling.md` - ML-specific error types and parsing.
- New guide: `guides/ml-telemetry.md` - ML telemetry events, GPU profiling, and metrics.

### Changed
- **ExDoc Configuration** - Added new module groups for Hardware, Reliability, ML Errors, and enhanced Telemetry.
- **Telemetry Module Groups** - Expanded to include Events, GPUProfiler, Span, and Handlers submodules.

## [0.7.7] - 2025-12-26

### Changed
- Pool GenServer initialization redesigned for OTP compliance. Worker startup now uses an async `spawn_link` pattern instead of blocking `receive` in `handle_continue`, keeping the GenServer responsive to shutdown signals during batch initialization.
- Multi-pool configuration now correctly isolates `pool_size` per pool. Each pool in `:pools` config uses its own `pool_size` value; the global `pool_config[:pool_size]` is only used in legacy single-pool mode.
- Test harness improvements: `after_suite` now monitors the supervisor and waits for actual termination before returning, preventing orphaned process warnings between test runs.
- ProcessRegistry defers unregistration when external OS processes are still alive, with automatic retry cleanup after process termination.

### Fixed
- Pool no longer crashes during application shutdown when WorkerSupervisor terminates before batch initialization completes. Added supervisor health checks before starting each worker batch.
- ProcessKiller `process_alive?/1` on Linux now detects zombie processes by reading `/proc/{pid}/stat` state, preventing false positives for terminated-but-not-reaped processes.
- Test configuration pollution fixed: tests that modify `:pools` config now properly save and restore `:pool_config` to prevent pool_size leakage between tests.

### Added
- `README_TESTING.md` updated with test isolation patterns, application lifecycle documentation, and multi-pool configuration examples for integration tests.
- `REMEDIATION_PLAN.md` documenting the root cause analysis and fixes for test harness race conditions.

## [0.7.6] - 2025-12-26

### Added
- Deterministic shutdown cleanup via `Snakepit.RuntimeCleanup` and manual cleanup via `Snakepit.cleanup/0`, with cleanup telemetry events.
- Process group lifecycle support with `process_group_kill`, pgid tracking in `ProcessRegistry`, and new `ProcessKiller` helpers for group kill/pgid lookup.
- Python gRPC servers can create their own process group when `SNAKEPIT_PROCESS_GROUP` is set.
- Python package management supports isolated virtualenvs via `:python_packages` `env_dir`, auto-creating venvs and honoring command timeouts.
- Documentation suites for FFI ergonomics, Python process cleanup, and runtime hygiene (docs/20251226/*).
- New tests for runtime cleanup, logger defaults, process group kill, process registry cleanup deferrals, and uv venv integration.

### Changed
- Quiet-by-default library config: `library_mode: true`, `log_level: :warning`, `grpc_log_level: :error`, `log_python_output: false`, plus new cleanup defaults (`cleanup_on_stop`, `cleanup_on_stop_timeout_ms`, `cleanup_poll_interval_ms`, `cleanup_retry_interval_ms`, `cleanup_max_retries`).
- Application supervision always starts `Snakepit.Pool.ProcessRegistry` and `Snakepit.Pool.ApplicationCleanup` even without pooling; `Application.stop/1` now runs a cleanup pass when enabled.
- gRPC worker startup/shutdown now tracks pgid/process_group, can kill process groups, buffers startup output, suppresses Python stdout unless enabled, and passes `SNAKEPIT_PROCESS_GROUP` while extending `PYTHONPATH` with SnakeBridge priv Python.
- `Snakepit.EnvDoctor` now locates `grpc_server.py` from the project or installed app root and expands `PYTHONPATH` to include Snakepit/SnakeBridge priv Python when running checks.
- Python runtime selection now prefers explicit overrides, then `:python_packages` venv Python, then managed/system fallback; package operations resolve Python from the configured venv.
- Cleanup retry timing for worker supervisor is now read from runtime config with `_ms` suffix.
- Version references updated to 0.7.6 in `mix.exs` and README dependency docs. Updated `supertester` to `v0.4.0`.

### Fixed
- Taint registry ETS initialization now tolerates a pre-existing table.
- Process registry cleanup no longer drops entries while external OS processes remain alive, and DETS is synced on cleanup/unregister.
- Startup failure diagnostics now include buffered Python output to aid gRPC server troubleshooting.

## [0.7.5] - 2025-12-25

### Added
- `Snakepit.PythonPackages` module for uv/pip package management.
- `Snakepit.PackageError` structured error type for package operations.
- `:python_packages` application config for installer, timeout, and env settings.
- `Snakepit.PythonPackages.ensure!/2` for provisioning required packages.
- `Snakepit.PythonPackages.check_installed/2` for verifying package presence.
- `Snakepit.PythonPackages.lock_metadata/2` for lockfile package metadata.
- `Snakepit.PythonPackages.installer/0` for reporting the active installer.
- `Snakepit.PythonPackages.install!/2` for direct requirement installs.

## [0.7.4] - 2025-12-25

### Added
- **Zero-copy interop** – `Snakepit.ZeroCopy` + `Snakepit.ZeroCopyRef` handle DLPack/Arrow exports/imports with explicit `close/1` and telemetry for export/import/fallback flows.
- **Crash barrier** – Worker crash classification, taint tracking, and idempotent retry policy with new crash/taint/restart telemetry events.
- **Hermetic Python runtime support** – uv-managed interpreter selection, bootstrap integration, and runtime identity metadata propagation.
- **Exception translation** – Structured Python error payloads mapped into `Snakepit.Error.*` exception structs with telemetry for mapped/unmapped translations.
- **Runtime contract coverage** – Integration test coverage for `kwargs`, `call_type`, and payload version fields.

### Changed
- **gRPC bridge error payloads** – Python gRPC servers now return JSON-structured error payloads for tooling failures.
- **Telemetry catalog** – Added runtime event listings for zero-copy, crash barrier, and exception translation.

### Fixed
- **Queue resiliency** – Tainted workers no longer drive queued requests; queue dispatch selects non-tainted workers when available.

## [0.7.3] - 2025-12-25

### Fixed
- **CI test infrastructure** – Fixed `python_integration` test failures in CI by starting `GRPC.Client.Supervisor` in `PythonIntegrationCase` setup and enabling pooling in `StreamingRegressionTest` setup.
- **EnvDoctor port check race condition** – Fixed intermittent `env_doctor_test` failures caused by `:grpc_port` check reading from global Application env instead of opts. The check now accepts `grpc_port` via opts (consistent with other state values), eliminating conflicts when tests or the application bind to overlapping port ranges.

## [0.7.2] - 2025-12-25

### Changed
- **Codebase cleanup** – Removed dead code, unused modules, and obsolete files across the Elixir and Python codebases.
- **Static analysis compliance** – Resolved Dialyzer warnings and Credo issues for cleaner, more maintainable code.
- **Documentation overhaul** – Rewrote README.md and ARCHITECTURE.md for v0.7.2; consolidated DIAGS.md and DIAGS2.md into a single DIAGRAMS.md with mermaid diagrams; updated all README_* guides with version markers; removed obsolete test_bidirectional.py and remaining_handlers.txt.

## [0.7.1] - 2025-12-24

### Added
- **Script ergonomics** – `Snakepit.run_as_script/2` now supports `restart`, `await_pool`, and `halt` options plus configurable shutdown/cleanup timeouts.
- **Example runner controls** – `examples/run_all.sh` honors `SNAKEPIT_EXAMPLE_DURATION_MS` and `SNAKEPIT_RUN_TIMEOUT_MS`.
- **Examples bootstrap helper** – `Snakepit.Examples.Bootstrap.run_example/2` centralizes pool readiness and script exit behavior.

### Changed
- **Pooling defaults to opt-in** – `pooling_enabled` now defaults to `false` to avoid auto-start surprises in scripts.
- **Examples cleanup** – bidirectional and documentation-only examples now shut down cleanly under both `mix run` and `run_all.sh`.

### Fixed
- **Mix-run config drift** – examples now restart Snakepit to apply script-level env overrides, preventing port mismatches and orphaned workers.

## [0.7.0] - 2025-12-22

### Added
- **Capacity-aware scheduling** – Pool tracks per-worker load and `threads_per_worker`, with `capacity_strategy` (`:pool` default, `:profile`, `:hybrid`) configurable globally or per pool.
- **Request metadata exposure** – Python SessionContext now carries `request_metadata` for adapters; `grpc_server.py` wraps ExecuteTool/ExecuteStreamingTool in telemetry spans.

### Changed
- **Correlation propagation** – gRPC calls now set `x-snakepit-correlation-id` headers and `ExecuteToolRequest.metadata` on execute + streaming paths; streaming calls ensure a correlation ID exists.
- **Process profile env merge** – Worker env defaults merge system thread limits with user overrides instead of replacing them.

### Fixed
- **ToolRegistry cleanup logging** – Cleanup logs now report the correct count of removed tools.

## [0.6.11] - 2025-12-20

### Added
- **Pool status CLI** – `mix snakepit.status` reports pool size, queue depth, and error counts without requiring a full dashboard stack.
- **Adapter generator** – `mix snakepit.gen.adapter` scaffolds a minimal Python adapter under `priv/python` with a ready-to-copy `adapter_args` snippet.
- **Binary gRPC results** – Bridge responses now include `binary_result` support so tools can return `{:binary, payload[, metadata]}` tuples for large outputs.
- **Examples runner** – `examples/run_all.sh` executes every example (including showcase/loadtest) via `mix run`, with auto-stop and configurable loadtest sizes.

### Changed
- **Doctor checks** – `Snakepit.EnvDoctor` validates the Elixir `grpc_port` and runs per-pool adapter import health checks via `grpc_server.py --health-check --adapter ...`.
- **Bootstrap consolidation** – scripts/docs/examples now standardize on `mix snakepit.setup` + `mix snakepit.doctor`, and examples prefer `mix run` with the shared bootstrap helper.
- **Python env defaults** – gRPC workers merge default `PYTHONPATH` and `SNAKEPIT_PYTHON` into adapter environments to keep imports predictable.
- **Docs organization** – legacy unified-bridge and unified-example design docs are archived, and install guidance now differentiates repo bootstrap from app usage.

### Fixed
- **Threaded server loop** – `grpc_server_threaded.py` now ensures a running asyncio event loop to avoid deprecation warnings.
- **Worker spawn telemetry** – gRPC worker spawn/terminate durations now use consistent monotonic units, preventing negative duration values in telemetry handlers.
- **Elixir tool decoding in Python** – `SessionContext.call_elixir_tool/2` decodes JSON/binary payloads via `TypeSerializer` instead of returning raw protobuf Any values.
- **Python ML workflow serialization** – showcase ML handlers coerce NumPy-derived stats into JSON-safe floats to avoid `orjson` errors.
- **Tool registration noise** – Python bridge caches tool registration per session and treats duplicate registrations as info, avoiding false error reports.

## [0.6.10] - 2025-11-13

### Added
- **Canonical worker metadata** – `Snakepit.Pool.Registry.metadata_keys/0` exposes the authoritative metadata keys (`:worker_module`, `:pool_name`, `:pool_identifier`, `:adapter_module`) and the surrounding docs call out how pool helpers, diagnostics, and worker profiles should treat that map as the single source of truth.
- **Telemetry catalog + filters** – `Snakepit.Telemetry.Naming.python_event_catalog/0` now documents the full event/measurement schema emitted by `snakepit_bridge`, while the Python telemetry stream implements glob-style allow/deny filters pushed from Elixir so noisy adapters can be muted without redeploying workers.
- **Async adapter registration** – `snakepit_bridge.base_adapter.BaseAdapter` adds `register_with_session_async/2` (plus regression coverage) so asyncio/aio stubs can advertise tool surfaces without blocking while the synchronous helper stays intact for classic stubs.
- **Self-managing Python tests** – `test_python.sh` now creates/updates `.venv`, fingerprints `priv/python/requirements.txt`, installs deps, regenerates protobuf stubs, and exports quiet OTEL defaults so `./test_python.sh` is a one-command pytest runner on any Linux/WSL host.

### Changed
- **Queue timeout enforcement** – Queued requests now carry their timer reference, the pool cancels those timers as soon as the request is dequeued or dropped, and statistics/logging happen in one place, preventing runaway timers when pools churn.
- **Threaded adapter guardrails** – `priv/python/grpc_server_threaded.py` refuses to boot adapters that don’t set `__thread_safe__ = True`, logging a clear remediation path and forcing unsafe adapters back to process mode.
- **Tool registration resilience** – `snakepit_bridge.base_adapter.BaseAdapter` wraps gRPC stub responses in `_coerce_stub_response/1`, unwrapping awaitables, `UnaryUnaryCall` structs, or lazy callables before checking `response.success`, which stabilizes adapters that mix sync and async gRPC stubs.
- **Heartbeat/schema documentation** – `Snakepit.Config` now ships typedocs for the normalized pool/heartbeat map shared with Python, and the architecture plus gRPC guides emphasize that BEAM is the authoritative heartbeat monitor with `SNAKEPIT_HEARTBEAT_CONFIG` kept in sync across languages.

### Fixed
- **Stale queue timeouts** – Queue timeout messages that arrive after a request has already been serviced are ignored, and clients now receive `{:error, :queue_timeout}` exactly once when their request is actually dropped.

## [0.6.9] - 2025-11-13

### Added
- **Registry helpers**: Introduced `Snakepit.Pool.Registry.fetch_worker/1` plus metadata helpers used throughout the pool, bridge server, worker profiles, and diagnostics so `worker_module`, `pool_identifier`, and `pool_name` are always looked up in a single, tested place.
- **Binary parameter validation**: `Snakepit.GRPC.BridgeServer` now rejects non-binary entries in `ExecuteToolRequest.binary_parameters`, guaranteeing local tools only ever see `{:binary, payload}` tuples while remote workers still receive the untouched proto map.
- **Slow-test workflow**: Tagged the long-running suites with `@tag :slow`, defaulted `mix test` to skip them, and documented the opt-in commands plus the 2025-11-13 slow-test inventory in `README_TESTING` and `docs/20251113/slow-test-report.md`.
- **Lifecycle observability**: Memory-based recycling now logs a warning whenever a worker cannot answer the `:get_memory_usage` probe, preventing silent configuration drift.
- **Rogue cleanup controls**: Operators can configure the exact script names and run-id markers that qualify Python processes for startup cleanup, with defaults matching `grpc_server.py`/`grpc_server_threaded.py`.
- **Memory recycle telemetry & diagnostics**: `[:snakepit, :worker, :recycled]` now emits `memory_mb`/`memory_threshold_mb`, Prometheus metrics expose `snakepit.worker.recycled` counters, and both `Snakepit.Diagnostics.ProfileInspector` plus `mix snakepit.profile_inspector` show per-pool “Memory Recycles” totals for operators.

### Changed
- **GRPC worker lookups**: GRPCWorker, ToolRegistry clients, pool helpers, and worker profiles call the new Registry helpers instead of `Registry.lookup/2`, ensuring metadata stays normalized and reverse lookups never crash when metadata is missing.
- **Bridge test coverage**: Added binary-parameter regression tests that prove malformed payloads are rejected before reaching Elixir tools, plus lifecycle tests that simulate failing memory probes.
- **Process killer tests**: Rogue cleanup unit tests now cover the customizable scripts/markers path so changes to the configuration surface immediately.
- **Heartbeat contract clarity**: Documented what `dependent: true|false` means, exported `SNAKEPIT_HEARTBEAT_CONFIG` expectations, and added both HeartbeatMonitor- and GRPCWorker-level regression tests so fail-fast vs independent behavior stays well defined.
- **Telemetry stream shutdown noise**: gRPC telemetry stream shutdowns that report `:normal` or `:shutdown` now log at debug level, eliminating the warning spam that buried actionable failures during slow-test runs.

### Fixed
- **Registry metadata race**: `Pool.Registry.put_metadata/2` now reports `{:error, :not_registered}` when clients attempt to attach metadata before the worker is registered and downgrades those expected attempts to debug logs, eliminating silent successes that previously returned `:ok`.
- **Heartbeat metrics stability**: The `snakepit.worker.memory_mb` summary now pulls values via `Map.get/2` and non-dependent monitors retain timeout/missed-heartbeat counters, so Telemetry/Prometheus exporters stop crashing when measurements arrive as maps and status checks reflect the real failure budget.
- **Docs parity**: README, README_GRPC, README_PROCESS_MANAGEMENT, and ARCHITECTURE now describe the binary parameter contract, registry helper usage, lifecycle behavior, and rogue cleanup assumptions introduced in this release.

## [0.6.8] - 2025-11-12

This release also rolls up the previously undocumented fail-fast docs/tests work from 074f2260f703d16ccfecf937c10af905165419f0 (heartbeat fail-fast suites, orphan cleanup stress tests, queue probe adapter, and config fail-fast coverage).

### Added
- **Bootstrap automation**: Introduced `Snakepit.Bootstrap`, `mix snakepit.setup`, and a `make bootstrap` target to install Mix deps, provision `.venv`/`.venv-py313`, install Python requirements, run `scripts/setup_test_pythons.sh`, and regenerate gRPC stubs with fully instrumented logging.
- **Environment doctor**: New `Snakepit.EnvDoctor` module plus `mix snakepit.doctor` task verify interpreter availability, `grpc` import, `.venv`/`.venv-py313`, `priv/python/grpc_server.py --health-check`, and worker port availability with actionable remediation messages.
- **Runtime guardrails**: `Snakepit.Application` now invokes `Snakepit.EnvDoctor.ensure_python!/0` before pools start, failing fast when Python prerequisites are missing. Test helpers (`test/support/fake_doctor.ex`, `test/support/bootstrap_runner.ex`, `test/support/command_runner.ex`) enable deterministic unit coverage for the bootstrap/doctor path.
- **Python-aware CI**: GitHub Actions workflow now runs bootstrap, doctor, the default suite, and `mix test --only python_integration` so bridge coverage is validated when the doctor passes.
- **New documentation**: README + README_TESTING describe the `make bootstrap → mix snakepit.doctor → mix test` workflow, explain how to run python integration tests, and highlight the new Mix tasks.
- **Lifecycle config & memory recycling**: Added `%Snakepit.Worker.LifecycleConfig{}` to capture adapter/profile/env data for every worker, wired `Snakepit.GRPCWorker` to answer `:get_memory_usage`, and extended lifecycle tests so TTL/request/memory recycling use the same canonical config.
- **Binary tool parameters**: `Snakepit.GRPC.BridgeServer`, `Snakepit.GRPC.Client`, and `Snakepit.GRPC.ClientImpl` now decode/forward `ExecuteToolRequest.binary_parameters`, exposing binaries to local tools as `{:binary, payload}` while sending the untouched map to Python workers. README.md and README_GRPC.md document the contract.
- **Worker-flow integration test**: New `Snakepit.Pool.WorkerFlowIntegrationTest` exercises the WorkerSupervisor → MockGRPCWorker path, ensuring registry/process tracking stays consistent after execution and crash/restart flows.
- **Randomized worker stress test**: `Snakepit.Pool.RandomWorkerFlowTest` throws randomized execute/kill sequences at pools to ensure Registry ↔ ProcessRegistry invariants hold under churn.

### Changed
- **Test gating**: Default `mix test` excludes `:python_integration` while Python-heavy suites (thread profile, session affinity, streaming regression, etc.) carry the tag; `test/unit/exunit_configuration_test.exs` locks the config in place.
- **Thread-profile test harness**: `Snakepit.ThreadProfilePython313Test` now uses `Snakepit.Test.PythonEnv.skip_unless_python_313/1` to skip cleanly when `.venv-py313` is unavailable.
- **Process killer regression**: Ports spawned during `kill_by_run_id/1` tests close via `safe_close_port/1`, eliminating `:port_close` race exceptions.
- **Queue saturation regression**: `Snakepit.Pool.QueueSaturationRuntimeTest` focuses on stats + agent tracking instead of brittle global ETS assertions, removing a common source of flaky failures.
- **gRPC generation script**: `priv/python/generate_grpc.sh` now prefers `.venv/bin/python3`, falling back to system `python3/python` only when the virtualenv is missing, and emits helpful logs when no interpreter is found.
- **Registry metadata semantics**: `Snakepit.GRPCWorker` now writes canonical metadata (`worker_module`, `pool_name`, `pool_identifier`) via `Snakepit.Pool.Registry.put_metadata/2`, unblocking pool-name extraction and worker-module discovery without parsing IDs. Tests cover PID→worker lookups.
- **LifecycleManager internals**: Tracking records store lifecycle structs instead of ad-hoc maps so replacement workers inherit adapter args/env, and memory thresholds now exercise the worker call path in tests.
- **Process cleanup safety**: Rogue process cleanup only targets commands containing `grpc_server.py`/`grpc_server_threaded.py` with `--snakepit-run-id/--run-id` flags, and operators can disable the sweep with `config :snakepit, :rogue_cleanup, enabled: false`. Docs explain the ownership contract.
- **Pool integration coverage**: Replaced the unstable `test/snakepit/pool/high_risk_flow_test.exs` harness with targeted unit-level integration coverage (WorkerSupervisor + MockGRPCWorker), keeping the suite reliable while still covering the critical registry/ProcessRegistry chain.
- **Worker profile metadata lookup**: Process/thread profiles now resolve worker modules via `Pool.Registry.get_worker_id_by_pid/1` + metadata lookup, so non-GRPC workers can be supported and Dialyzer warnings are gone.

### Fixed
- Shell instrumentation around bootstrap (reporting command start/finish and verbose pip output) prevents "silent hangs" and surfaced the root causes of previous provisioning confusion.
- `scripts/setup_test_pythons.sh` now runs under `set -x`, streaming its progress during bootstrap.
- Rogue cleanup tests verify we no longer kill unrelated Python processes, and docs call out the run-id requirements so multi-tenant hosts stay safe.


## [0.6.7] - 2025-10-28

### Added

#### Phase 1: Type System MVP + Performance
- **6x JSON performance boost**: Integrated `orjson` for Python serialization, delivering 4-6x speedup for raw JSON operations and 1.5x improvement for large payloads (`priv/python/snakepit_bridge/serialization.py`, `priv/python/tests/test_orjson_integration.py`).
- **Structured error type**: New `Snakepit.Error` struct provides detailed context for debugging with fields including `category`, `message`, `details`, `python_traceback`, and `grpc_status` (`lib/snakepit/error.ex`, `test/unit/error_test.exs`).
- **Complete type specifications**: All public API functions in `Snakepit` module now have `@spec` annotations with structured error return types for better IDE support and Dialyzer analysis.
- **Performance benchmarks**: Comprehensive benchmark suite validates 4-6x raw JSON speedup and verifies no regression on small payloads (`priv/python/tests/test_orjson_integration.py`).

#### Phase 2: Distributed Telemetry System
- **Bidirectional telemetry streaming**: Python workers can now emit telemetry events via gRPC that are re-emitted as Elixir `:telemetry` events for unified observability (`lib/snakepit/telemetry/grpc_stream.ex`, `priv/python/snakepit_bridge/telemetry/`).
- **Complete event catalog**: 43 telemetry events across 3 layers (Infrastructure, Python Execution, gRPC Bridge) with atom-safe event names to prevent atom table exhaustion (`lib/snakepit/telemetry/naming.ex`, `docs/20251028/telemetry/01_EVENT_CATALOG.md`).
- **Python telemetry API**: High-level Python API with `telemetry.emit()` for events and `telemetry.span()` for automatic timing, plus correlation ID propagation across the Elixir/Python boundary (`priv/python/snakepit_bridge/telemetry/__init__.py`).
- **Runtime telemetry control**: Adjust sampling rates, enable/disable telemetry, and filter events for individual workers without restarts (`lib/snakepit/telemetry/control.ex`).
- **Metadata safety**: Automatic sanitization of Python metadata to prevent atom table exhaustion from untrusted string keys (`lib/snakepit/telemetry/safe_metadata.ex`).
- **Multiple backend support**: Python telemetry supports gRPC streaming (default) and stderr backends, with extensible backend architecture (`priv/python/snakepit_bridge/telemetry/backends/`).
- **Worker lifecycle hooks**: Automatic telemetry stream registration/unregistration integrated into worker lifecycle (`lib/snakepit/grpc_worker.ex:479`, `lib/snakepit/grpc_worker.ex:783`).
- **Integration tests**: Comprehensive test suite covering event catalog, validation, sanitization, and control messages (`test/integration/telemetry_flow_test.exs`).

### Changed
- Python serialization now uses `orjson` with graceful fallback to stdlib `json` if orjson is unavailable, maintaining full backward compatibility.
- Error returns in `Snakepit.Pool` and `Snakepit` modules now use structured `Snakepit.Error` types with detailed context instead of atoms.
- `Snakepit.Pool.await_ready/2` now returns `{:error, %Snakepit.Error{category: :timeout}}` instead of `{:error, :timeout}`.
- Streaming validation errors now include adapter context in error details.
- Old `telemetry.span()` (OpenTelemetry) renamed to `telemetry.otel_span()` to avoid naming conflict with new telemetry streaming span.
- `Snakepit.Application` supervision tree now includes `Snakepit.Telemetry.GrpcStream` for managing bidirectional telemetry streams.

### Fixed
- Updated Dialyzer type specifications to match new structured error returns, reducing type warnings.
- Corrected `grpc_worker.ex` metadata fields for telemetry events (`state.stats.start_time`, `state.stats.requests`).

### Documentation
- **New `TELEMETRY.md`**: Complete user guide for the distributed telemetry system with usage examples, integration patterns for Prometheus/StatsD/OpenTelemetry, and troubleshooting guidance (320 lines).
- **Telemetry design docs**: 9 comprehensive design documents covering architecture, event catalog, Python integration, client guide, gRPC implementation, and backend architecture (`docs/20251028/telemetry/`).
- **New examples**: 5 comprehensive examples demonstrating v0.6.7 features with ~50KB of production-ready code:
  - `examples/telemetry_basic.exs` - Introduction to telemetry handlers and Python telemetry API
  - `examples/telemetry_advanced.exs` - Correlation tracking, performance monitoring, runtime control
  - `examples/telemetry_monitoring.exs` - Production monitoring patterns with real-time dashboard
  - `examples/telemetry_metrics_integration.exs` - Prometheus/StatsD integration patterns
  - `examples/structured_errors.exs` - New `Snakepit.Error` struct usage and pattern matching
- **Updated `examples/README.md`**: Comprehensive guide to all examples with clear learning paths and troubleshooting.
- Updated README.md with v0.6.7 release notes highlighting type system improvements, performance gains, and telemetry system.
- Updated mix.exs version to 0.6.7 with `TELEMETRY.md` in package files and docs extras.
- Added comprehensive test coverage for structured error types (12 new tests in `test/unit/error_test.exs`).

### Performance
- **Telemetry overhead**: <10μs per event, <1% CPU impact at 100% sampling, <0.1% CPU at 10% sampling.
- **Bounded resources**: Python telemetry queue limited to 1024 events (~100KB), with graceful degradation (drops events vs blocking).
- **Zero regression**: All 235+ existing tests pass with full backward compatibility maintained.

**Zero breaking changes**: All existing code continues to work. Telemetry is fully opt-in via standard `:telemetry.attach()` patterns.

## [0.6.6] - 2025-10-27

### Added
- Configurable session/program quotas now surface tagged errors when limits are exceeded, with regression coverage in `test/unit/bridge/session_store_test.exs`.
- Introduced a logger redaction helper so adapters and bridge code can log sensitive inputs safely (`test/unit/logger/redaction_test.exs`).

### Changed
- `Snakepit.GRPC.BridgeServer` reuses worker-owned gRPC channels and only dials a disposable connection when the worker has not yet published one; fallbacks are closed after each invocation.
- gRPC streaming helpers document and enforce the JSON-plus-metadata chunk envelope, clarifying `_metadata` and `raw_data_base64` handling.
- Worker startup handshake waits for the negotiated gRPC port before publishing worker metadata, eliminating transient routing failures during boot.
- `Snakepit.GRPC.ClientImpl` now returns structured `{:error, {:invalid_parameter, :json_encode_failed, message}}` tuples when parameters cannot be JSON-encoded, preventing calling processes from crashing (`test/unit/grpc/client_impl_test.exs`).
- `Snakepit.GRPC.BridgeServer.execute_streaming_tool/2` raises `UNIMPLEMENTED` with remediation guidance so callers can fall back gracefully when streaming is disabled (`test/snakepit/grpc/bridge_server_test.exs`).

### Fixed
- `Snakepit.GRPCWorker` persists the OS-assigned port discovered during startup so BridgeServer never receives `0` when routing requests (`test/unit/grpc/grpc_worker_ephemeral_port_test.exs`).
- Parameter decoding now rejects malformed protobuf payloads with descriptive `{:invalid_parameter, key, reason}` errors, preventing unexpected crashes (`test/snakepit/grpc/bridge_server_test.exs`).
- Process registry ETS tables are `:protected` and DETS handles remain private, guarding against external mutation attempts (`test/unit/pool/process_registry_security_test.exs`).
- Pool name inference prefers registry metadata and logs once when falling back to worker-id parsing, eliminating silent misroutes (`test/unit/pool/pool_registry_lookup_test.exs`).

### Documentation
- Refreshed README, gRPC guides (including the streaming and quick reference docs), and testing notes to cover port persistence, channel reuse, quota enforcement, DETS/ETS protections, streaming payload envelopes and fallbacks, metadata-driven pool routing, logging redaction guardrails, and the expanded regression suite.

## [0.6.5] - 2025-10-26

### Added
- Regression suites covering worker supervisor stop/restart flows and profile-level shutdown helpers (`test/unit/pool/worker_supervisor_test.exs`, `test/unit/worker_profile/worker_profile_stop_worker_test.exs`).

### Changed
- `Snakepit.Application` now reads the current environment from compile-time configuration instead of calling `Mix.env/0`, keeping OTP releases Mix-free.
- Introduced `Snakepit.PythonThreadLimits.resolve/1` to merge partial thread-limit overrides with defaults before applying environment variables.

### Fixed
- `Snakepit.Pool.WorkerSupervisor.stop_worker/1` targets worker starter supervisors and accepts either worker ids or pids, ensuring restarts actually decommission the old worker.
- `Snakepit.WorkerProfile.Process` and `Snakepit.WorkerProfile.Thread` resolve worker ids through the pool registry so lifecycle manager shutdowns succeed for pid handles.

## [0.6.4] - 2025-10-30

### Added
- Streaming regression guard in `test/snakepit/streaming_regression_test.exs` covering both success and adapter capability failures
- `examples/stream_progress_demo.exs` showcasing five timed streaming updates with rich progress output
- `test_python.sh` helper that regenerates protobuf stubs, activates the project virtualenv, wires `PYTHONPATH`, and forwards arguments to `pytest`

### Changed
- Python gRPC servers now bridge streaming iterators through an `asyncio.Queue`, yielding chunks as soon as they are produced and removing ad-hoc log files
- `Snakepit.Adapters.GRPCPython` consumes streaming chunks incrementally, decoding JSON payloads, surfacing metadata, and safeguarding callback failures
- Showcase `stream_progress` tool accepts `delay_ms` and reports elapsed timing so demos and diagnostics show meaningful pacing

### Fixed
- Eliminated burst delivery of streaming responses by ensuring each chunk is forwarded to Elixir immediately, restoring real-time feedback for `execute_stream/4`

---

## [0.6.3] - 2025-10-19

### Added
- **Dependent/Independent Heartbeat Mode** - New `dependent` configuration flag allows workers to optionally continue running when Elixir heartbeats fail, enabling debugging scenarios where Python workers should remain alive
- Environment variable-based heartbeat configuration via `SNAKEPIT_HEARTBEAT_CONFIG` for passing settings from Elixir to Python workers
- Python unit test coverage for dependent heartbeat termination behavior (`priv/python/tests/test_heartbeat_client.py`)
- CLI flags `--heartbeat-dependent` and `--heartbeat-independent` for Python gRPC server configuration

### Changed
- Default heartbeat enabled state changed from `false` to `true` for better production reliability
- `HeartbeatMonitor` now suppresses worker termination when `dependent: false` is configured, logging warnings instead
- Python `HeartbeatClient` includes default shutdown handler for dependent mode
- `Snakepit.GRPCWorker` passes heartbeat configuration to Python via environment variables
- Updated configuration tests to reflect new heartbeat defaults

### Fixed
- Heartbeat configuration now properly propagates from Elixir to Python across all code paths

---

## [0.6.2] - 2025-10-26

### Added
- End-to-end heartbeat regression suite covering monitor boot, timeout handling, and OS-level process cleanup (`test/snakepit/grpc/heartbeat_end_to_end_test.exs`)
- Long-running heartbeat stability test to guard against drift and missed ping accumulation (`test/snakepit/heartbeat_monitor_test.exs`)
- Python-side telemetry regression ensuring outbound metadata preserves correlation identifiers (`priv/python/tests/test_telemetry.py`)
- Deep-dive documentation for the heartbeat and observability stack plus consolidated testing command guide (`docs/20251019/*.md`)

### Changed
- `Snakepit.GRPCWorker` now terminates itself whenever the heartbeat monitor exits, preventing pools from keeping unhealthy workers alive
- `make test` preferentially uses the repository’s virtualenv interpreter, exports `PYTHONPATH`, and runs `mix test --color` for consistent local runs

### Fixed
- Guard against leaking heartbeat monitors by stopping the worker when the monitor crashes, ensuring registry entries and OS ports are released

---

## [0.6.1] - 2025-10-19

### Added
- Proactive worker heartbeat monitoring via `Snakepit.HeartbeatMonitor` with configurable cadence, miss thresholds, and per-pool overrides
- Comprehensive telemetry stack: `Snakepit.Telemetry.OpenTelemetry` boot hook, `Snakepit.TelemetryMetrics` Prometheus exporter, and correlation helpers for tracing spans
- Rich gRPC client utilities (`Snakepit.GRPC.ClientImpl`) covering ping, session lifecycle, heartbeats, and streaming tooling
- Python bridge instrumentation (`snakepit_bridge.heartbeat`, `snakepit_bridge.telemetry`) plus new unit tests for telemetry and threaded servers
- Default telemetry/heartbeat configuration shipped in `config/config.exs`, including OTLP environment toggles and Prometheus port selection
- Configurable logging system via the new `Snakepit.Logger` module with centralized control over verbosity (`:debug`, `:info`, `:warning`, `:error`, `:none`)

### Changed
- `Snakepit.GRPCWorker` now emits detailed telemetry, manages heartbeats, and wires correlation IDs through tracing spans
- `Snakepit.Application` activates OTLP exporters based on environment variables, registers telemetry reporters alongside pool supervisors, and routes logs through `Snakepit.Logger`
- Python gRPC servers (`grpc_server.py`, `grpc_server_threaded.py`) updated with structured logging, execution metrics, and heartbeat responses
- Examples refreshed with observability storylines, dual-mode telemetry demos, and cleaner default output through `Snakepit.Logger`
- GitHub workflows tightened to reflect new test layout and planning artifacts
- 25+ Elixir modules migrated to `Snakepit.Logger` for consistent log suppression in demos and production

### Configuration
- New `:log_level` option under the `:snakepit` application config to control internal logging
  ```elixir
  # config/config.exs
  config :snakepit,
    log_level: :warning  # Options: :debug, :info, :warning, :error, :none
  ```

### Fixed
- Hardened CI skips for `ApplicationCleanupTest` to avoid nondeterministic BEAM run IDs
- Addressed flaky test ordering through targeted cleanup helpers and telemetry-aware assertions

### Documentation
- Major rewrite of `ARCHITECTURE.md`, new `AGENTS.md`, and comprehensive design dossiers for v0.7/v0.8 feature tracks
- Added heartbeat, telemetry, and OTLP upgrade plans under `docs/2025101x/`
- README refreshed with v0.6.1 highlights, logging guidance, installation tips, and observability walkthroughs

### Notes
- Existing configurations continue to work with the default `:info` log level
- Log suppression is optional—set `log_level: :debug` to restore verbose output
- Provides cleaner logs for production deployments and demos while retaining full visibility for debugging

---

## [0.6.0] - 2025-10-11

### Added - Phase 1: Dual-Mode Architecture Foundation

- **Worker Profile System**
  - New `Snakepit.WorkerProfile` behaviour for pluggable parallelism strategies
  - `Snakepit.WorkerProfile.Process` - Multi-process profile (default, backward compatible)
  - `Snakepit.WorkerProfile.Thread` - Multi-threaded profile stub (Phase 2-3 implementation)
  - Profile abstraction enables switching between process and thread execution modes

- **Python Environment Detection**
  - New `Snakepit.PythonVersion` module for Python version detection
  - Automatic detection of Python 3.13+ free-threading support (PEP 703)
  - Profile recommendation based on Python capabilities
  - Version validation and compatibility warnings

- **Library Compatibility Matrix**
  - New `Snakepit.Compatibility` module with thread-safety database
  - Compatibility tracking for 20+ popular Python libraries (NumPy, PyTorch, Pandas, etc.)
  - Per-library thread safety status, recommendations, and workarounds
  - Automatic compatibility checking for thread profile configurations

- **Configuration System Enhancements**
  - New `Snakepit.Config` module for multi-pool configuration management
  - Support for named pools with different worker profiles
  - Backward-compatible legacy configuration conversion
  - Comprehensive configuration validation and normalization
  - Profile-specific defaults (process vs thread)

- **Documentation**
  - Comprehensive v0.6.0 technical plan (8,000+ words)
  - GIL removal research and dual-mode architecture design
  - Phase-by-phase implementation roadmap (10 weeks)
  - Performance benchmarks and migration strategies

### Changed

- **Architecture Evolution**
  - Foundation laid for Python 3.13+ free-threading support
  - Worker management abstracted to support multiple parallelism models
  - Configuration system generalized for multi-pool scenarios

### Added - Phase 2: Multi-Threaded Python Worker

- **Threaded gRPC Server**
  - New `grpc_server_threaded.py` - Multi-threaded server with ThreadPoolExecutor
  - Concurrent request handling via HTTP/2 multiplexing
  - Thread safety monitoring with `ThreadSafetyMonitor` class
  - Request tracking per thread with performance metrics
  - Automatic adapter thread safety validation on startup
  - Configurable thread pool size (--max-workers parameter)

- **Thread-Safe Adapter Infrastructure**
  - New `base_adapter_threaded.py` - Base class for thread-safe adapters
  - `ThreadSafeAdapter` with built-in locking primitives
  - `ThreadLocalStorage` manager for per-thread state
  - `RequestTracker` for monitoring concurrent requests
  - `@thread_safe_method` decorator for automatic tracking
  - Context managers for safe lock acquisition
  - Built-in statistics and performance monitoring

- **Example Implementations**
  - `threaded_showcase.py` - Comprehensive thread-safe adapter example
  - Pattern 1: Shared read-only resources (models, configurations)
  - Pattern 2: Thread-local storage (caches, buffers)
  - Pattern 3: Locked shared mutable state (counters, logs)
  - CPU-intensive workloads with NumPy integration
  - Stress testing and performance monitoring tools
  - Example tools: compute_intensive, matrix_multiply, batch_process, stress_test

- **Thread Safety Validation**
  - New `thread_safety_checker.py` - Runtime validation toolkit
  - Concurrent access detection with detailed warnings
  - Known unsafe library detection (Pandas, Matplotlib, SQLite3)
  - Thread contention monitoring and analysis
  - Performance profiling per thread
  - Automatic recommendations for detected issues
  - Global checker with strict mode option

- **Documentation**
  - New `README_THREADING.md` - Comprehensive threading guide
  - Thread safety patterns and best practices
  - Writing thread-safe adapters tutorial
  - Testing strategies for concurrent code
  - Performance optimization techniques
  - Library compatibility matrix (20+ libraries)
  - Common pitfalls and solutions
  - Advanced topics: worker recycling, monitoring, debugging

### Added - Phase 3: Elixir Thread Profile Integration

- **Complete ThreadProfile Implementation**
  - Full implementation of `Snakepit.WorkerProfile.Thread`
  - Worker capacity tracking via ETS table (`:snakepit_worker_capacity`)
  - Atomic load increment/decrement for thread-safe capacity management
  - Support for concurrent requests to same worker (HTTP/2 multiplexing)
  - Automatic script selection (threaded vs standard gRPC server)

- **Worker Capacity Management**
  - ETS-based capacity tracking: `{worker_pid, capacity, current_load}`
  - Atomic operations for thread-safe load updates
  - Capacity checking before request execution
  - Automatic load decrement after request completion (even on error)
  - Real-time capacity monitoring via `get_capacity/1` and `get_load/1`

- **Adapter Configuration Enhancement**
  - Updated `GRPCPython.script_path/0` to select correct server variant
  - Automatic detection of threaded mode from adapter args
  - Seamless switching between process and thread servers
  - Enhanced argument merging for user customization

- **Load Balancing**
  - Capacity-aware worker selection
  - Prevents over-subscription of workers
  - Returns `:worker_at_capacity` when no slots available
  - Automatic queueing handled by pool layer

- **Example Demonstration**
  - New `examples/threaded_profile_demo.exs` - Interactive demo script
  - Shows configuration patterns for threaded mode
  - Explains concurrent request handling
  - Demonstrates capacity management
  - Performance monitoring examples

### Added - Phase 4: Worker Lifecycle Management

- **LifecycleManager GenServer**
  - New `Snakepit.Worker.LifecycleManager` - Automatic worker recycling
  - TTL-based recycling (configurable: seconds/minutes/hours/days)
  - Request-count based recycling (recycle after N requests)
  - Memory threshold recycling (optional, requires worker support)
  - Periodic health checks (every 5 minutes)
  - Graceful worker replacement with zero downtime

- **Worker Tracking Infrastructure**
  - Automatic worker registration on startup
  - Per-worker metadata tracking (start time, request count, config)
  - Process monitoring for crash detection
  - Lifecycle statistics and reporting

- **Recycling Logic**
  - Configurable TTL: `{3600, :seconds}`, `{1, :hours}`, etc.
  - Max requests: `worker_max_requests: 1000`
  - Memory threshold: `memory_threshold_mb: 2048` (optional)
  - Manual recycling: `LifecycleManager.recycle_worker(pool, worker_id)`
  - Automatic replacement after recycling

- **Request Counting**
  - Automatic increment after successful request
  - Per-worker request tracking
  - Triggers recycling at configured threshold
  - Integrated with Pool's execute path

- **Telemetry Events**
  - `[:snakepit, :worker, :recycled]` - Worker recycled with reason
  - `[:snakepit, :worker, :health_check_failed]` - Health check failure
  - Rich metadata (worker_id, pool, reason, uptime, request_count)
  - Integration with Prometheus, LiveDashboard, custom monitors

- **Documentation**
  - New `docs/telemetry_events.md` - Complete telemetry reference
  - Event schemas and metadata descriptions
  - Usage examples for monitoring systems
  - Prometheus and LiveDashboard integration patterns
  - Best practices and debugging tips

- **Supervisor Integration**
  - LifecycleManager added to application supervision tree
  - Positioned after WorkerSupervisor, before Pool
  - Automatic startup with pooling enabled
  - Clean shutdown handling

### Changed - Phase 4

- **GRPCWorker Enhanced**
  - Workers now register with LifecycleManager on startup
  - Lifecycle config passed during initialization
  - Untracking on worker shutdown

- **Pool Enhanced**
  - Request counting integrated into execute path
  - Automatic notification to LifecycleManager on success
  - Supports lifecycle management without modifications to existing flow

### Added - Phase 5: Enhanced Diagnostics and Monitoring

- **ProfileInspector Module**
  - New `Snakepit.Diagnostics.ProfileInspector` - Programmatic pool inspection
  - Functions for pool statistics, capacity analysis, and memory usage
  - Profile-aware metrics for both process and thread pools
  - `get_pool_stats/1` - Comprehensive pool statistics
  - `get_capacity_stats/1` - Capacity utilization and thread info
  - `get_memory_stats/1` - Memory usage breakdown per worker
  - `get_comprehensive_report/0` - All pools analysis
  - `check_saturation/2` - Capacity warning system
  - `get_recommendations/1` - Intelligent optimization suggestions

- **Mix Task: Profile Inspector**
  - New `mix snakepit.profile_inspector` - Interactive pool inspection tool
  - Text and JSON output formats
  - Detailed per-worker statistics with `--detailed` flag
  - Pool-specific inspection with `--pool` option
  - Optimization recommendations with `--recommendations` flag
  - Color-coded utilization indicators (🔴🟡🟢⚪)
  - Profile-specific insights (process vs thread)

- **Enhanced Scaling Diagnostics**
  - Extended `mix diagnose.scaling` with profile-aware analysis
  - New TEST 0: Pool Profile Analysis
  - Thread pool vs process pool comparison
  - Capacity utilization monitoring
  - Profile-specific recommendations
  - System-wide optimization opportunities
  - Real-time pool statistics integration

- **Telemetry Events**
  - `[:snakepit, :pool, :saturated]` - Pool queue at max capacity
    - Measurements: `queue_size`, `max_queue_size`
    - Metadata: `pool`, `available_workers`, `busy_workers`
  - `[:snakepit, :pool, :capacity_reached]` - Worker reached capacity (thread profile)
    - Measurements: `capacity`, `load`
    - Metadata: `worker_pid`, `profile`, `rejected` (optional)
  - `[:snakepit, :request, :executed]` - Request completed with duration
    - Measurements: `duration_us` (microseconds)
    - Metadata: `pool`, `worker_id`, `command`, `success`

- **Diagnostic Features**
  - Worker memory usage tracking per process
  - Thread pool utilization analysis
  - Capacity saturation warnings
  - Profile-appropriate recommendations
  - Performance duration tracking
  - Queue depth monitoring

### Status

- **Phase 1** ✅ Complete - Foundation modules and behaviors defined
- **Phase 2** ✅ Complete - Multi-threaded Python worker implementation
- **Phase 3** ✅ Complete - Elixir thread profile integration
- **Phase 4** ✅ Complete - Worker lifecycle management and recycling
- **Phase 5** ✅ Complete - Enhanced diagnostics and monitoring
- **Phase 6** 🔄 Pending - Documentation and examples

### Notes

- **No Breaking Changes**: All v0.5.1 configurations remain fully compatible
- **Thread Profile**: Stub implementation (returns `:not_implemented`) until Phase 2-3
- **Default Behavior**: Process profile remains default for maximum stability
- **Python 3.13+**: Free-threading support enables true multi-threaded workers
- **Migration**: Existing code requires zero changes to continue working

---

## [0.5.1] - 2025-10-11

### Added
- **Diagnostic Tools**
  - New `mix diagnose.scaling` task for comprehensive bottleneck analysis
  - Captures resource metrics (ports, processes, TCP connections, memory usage)
  - Enhanced error logging with port buffer drainage

- **Configuration Enhancements**
  - Explicit gRPC port range constraint documentation and validation
  - Batched worker startup configuration (`startup_batch_size: 8`, `startup_batch_delay_ms: 750`)
  - Resource limit safeguards with `max_workers: 1000` hard limit

### Changed
- **Worker Pool Scaling Improvements**
  - Pool now reliably scales to 250+ workers (previously limited to ~105)
  - Resolved thread explosion during concurrent startup (fixed "fork bomb" issue)
  - Dynamic port allocation using OS-assigned ports (port=0) eliminates port collision races
  - Batched worker startup prevents system resource exhaustion during concurrent initialization

- **Performance Optimizations**
  - Aggressive thread limiting via environment variables for optimal pool-level parallelism:
    - `OPENBLAS_NUM_THREADS=1` (numpy/scipy)
    - `OMP_NUM_THREADS=1` (OpenMP)
    - `MKL_NUM_THREADS=1` (Intel MKL)
    - `NUMEXPR_NUM_THREADS=1` (NumExpr)
    - `GRPC_POLL_STRATEGY=poll` (single-threaded)
  - Increased GRPC server connection backlog to 512
  - Extended worker ready timeout to 30s for large pools

- **Configuration Updates**
  - Increased `port_range` to 1000 (accommodates `max_workers`)
  - Enhanced configuration comments explaining each tuning parameter
  - Resource usage tracking during pool initialization

### Fixed
- **Concurrent Startup Issues**
  - Fixed "Cannot fork" / EAGAIN errors from thread explosion during worker spawn
  - Eliminated port collision races with dynamic port allocation
  - Resolved fork bomb caused by Python scientific libraries spawning excessive threads (6,000+ threads from OpenBLAS, gRPC, MKL)

- **Resource Management**
  - Better port binding error handling in Python gRPC server
  - Improved error diagnostics during pool initialization
  - Enhanced connection management in GRPC server

### Performance
- Successfully tested with 250 workers (2.5x previous limit)
- Startup time increases with pool size (~60s for 250 workers vs ~10s for 100 workers)
- Eliminated port collision races and fork resource exhaustion
- Dynamic port allocation provides reliable scaling

### Notes
- Thread limiting optimizes for high concurrency with many small tasks
- CPU-intensive workloads that perform heavy numerical computation within a single task may need different threading configuration
- For computationally intensive per-task workloads, consider:
  - Workload-specific environment variables passed per task
  - Separate worker pools with different threading profiles
  - Dynamic thread limit adjustment based on task type
  - Allowing higher OpenBLAS threads but reducing max_workers accordingly
- See commit dc67572 for detailed technical analysis and future considerations

---

## [0.5.0] - 2025-10-10

### Added
- **Process Management & Lifecycle**
  - New `Snakepit.RunId` module for unique process run identification with nanosecond precision
  - New `Snakepit.ProcessKiller` module for robust OS-level process cleanup with SIGTERM/SIGKILL escalation
  - Enhanced `ProcessRegistry` with run_id tracking and improved cleanup logic
  - Added `scripts/setup_python.sh` for automated Python environment setup

- **Test Infrastructure Improvements**
  - Added comprehensive Supertester refactoring plan (SUPERTESTER_REFACTOR_PLAN.md)
  - Phase 1 foundation updates complete with TestableGenServer support
  - New `assert_eventually` helper for polling conditions without Process.sleep
  - Enhanced test documentation and baseline establishment
  - New worker lifecycle tests for process management validation
  - New application cleanup tests with run_id integration

- **Python Cleanup & Testing**
  - Created Python test infrastructure with `test_python.sh` script
  - Added comprehensive SessionContext test suite (15 tests)
  - Created Elixir integration tests for Python SessionContext (9 tests)
  - Python cleanup summary documentation (PYTHON_CLEANUP_SUMMARY.md)
  - Enhanced Python gRPC server with improved process management and signal handling

- **Documentation**
  - Phase 1 completion report with detailed test results
  - Python cleanup and testing infrastructure summary
  - Enhanced test planning and refactoring documentation
  - Added comprehensive process management design documents (robust_process_cleanup_with_run_id.md)
  - Added implementation summaries and debugging session reports
  - New production deployment checklist (PRODUCTION_DEPLOYMENT_CHECKLIST.md)
  - New example status documentation (EXAMPLE_STATUS_FINAL.md)
  - Enhanced README with new icons and improved organization
  - Added README_GRPC.md and README_BIDIRECTIONAL_TOOL_BRIDGE.md
  - Created docs/archive/ structure for historical analysis and design documents

- **Assets & Branding**
  - Added 29 new SVG icons for documentation (architecture, binary, book, bug, chart, etc.)
  - New snakepit-icon.svg for branding
  - Enhanced visual documentation throughout

### Changed
- **Process Management Improvements**
  - `ApplicationCleanup` rewritten with run_id-based cleanup strategy
  - `GRPCWorker` enhanced with run_id tracking and improved termination handling
  - `ProcessRegistry` optimized cleanup from O(n) to O(1) operations using run_id
  - Enhanced `GRPCPython` adapter with run_id support

- **Code Cleanup**
  - Removed dead Python code
  - Deleted obsolete backup files and unused modules
  - Streamlined Python SessionContext
  - Cleaned up test infrastructure and removed duplicate code
  - Archived ~60 historical documentation files to docs/archive/

- **Examples Refactoring**
  - Simplified grpc_streaming_demo.exs
  - Refactored grpc_advanced.exs for better clarity
  - Enhanced grpc_sessions.exs with improved structure
  - Streamlined grpc_streaming.exs
  - Improved grpc_concurrent.exs with better patterns

- **Test Coverage**
  - Increased total test coverage from 27 to 51 tests (+89%)
  - 37 Elixir tests passing (27 + 9 new integration tests + 1 new helper test)
  - 15 Python SessionContext tests passing
  - Enhanced test helpers with improved synchronization and cleanup

- **Build Configuration**
  - Enhanced mix.exs with expanded documentation and package metadata
  - Updated dependencies and build configurations

### Removed
- **DSPy Integration** (as announced in v0.4.3)
  - Removed deprecated `dspy_integration.py` module
  - Removed deprecated `types.py` with VariableType enum
  - Removed `session_context.py.backup`
  - Removed obsolete `test_server.py`
  - Removed unused CLI directory referencing non-existent modules
  - All `__pycache__/` directories cleaned up

- **Variables Feature (Temporary Removal)**
  - Removed incomplete variables implementation pending future redesign:
    - `lib/snakepit/bridge/variables.ex`
    - `lib/snakepit/bridge/variables/variable.ex`
    - `lib/snakepit/bridge/variables/types.ex`
    - All variable type modules (boolean, choice, embedding, float, integer, module, string, tensor)
    - `examples/grpc_variables.exs`
    - `lib/snakepit_showcase/demos/variables_demo.ex`
    - Related test files and Python code

- **Deprecated Components**
  - Removed `lib/snakepit/bridge/serialization.ex`
  - Removed `lib/snakepit/grpc/stream_handler.ex`
  - Removed integration test infrastructure (`test/integration/` directory)
  - Removed property-based tests pending refactor
  - Removed session and serialization tests pending redesign

### Fixed
- **Process Cleanup & Lifecycle**
  - Fixed race conditions in worker cleanup and termination
  - Improved OS-level process cleanup with proper signal handling
  - Enhanced DETS cleanup with run_id-based identification
  - Fixed test flakiness with improved synchronization

- **gRPC & Session Management**
  - Improved session initialization and cleanup in Python gRPC server
  - Enhanced error handling in bidirectional tool bridge
  - Better isolation between test runs

- **Test Infrastructure**
  - Isolation level configuration documented (staying with :basic until test refactoring)
  - Test infrastructure conflicts between manual cleanup and Supertester automatic cleanup resolved
  - Enhanced debugging capabilities for test failures

### Notes
- **Breaking Changes**:
  - DSPy integration fully removed (deprecated in v0.4.3)
  - Variables feature temporarily removed pending redesign
  - Users must migrate to DSPex for DSPy functionality (see v0.4.3 migration guide)
- Test suite reliability improved with better synchronization patterns
- Foundation laid for full Supertester conformance in future releases
- Process management significantly improved with run_id tracking system
- Documentation reorganized with archive structure for historical content

---

## [0.4.3] - 2025-10-07

### Deprecated
- **DSPy Integration** (`snakepit_bridge.dspy_integration`)
  - Deprecated in favor of DSPex-native integration
  - Will be removed in v0.5.0
  - Deprecation warnings added to all DSPy-specific classes:
    - `VariableAwarePredict`
    - `VariableAwareChainOfThought`
    - `VariableAwareReAct`
    - `VariableAwareProgramOfThought`
    - `ModuleVariableResolver`
    - `create_variable_aware_program()`
  - See migration guide: https://github.com/nshkrdotcom/dspex/blob/main/docs/architecture_review_20251007/04_DECOUPLING_PLAN.md

### Changed
- **VariableAwareMixin** docstring updated to emphasize generic applicability
  - Clarified it's generic, not DSPy-specific
  - Can be used with any Python library (scikit-learn, PyTorch, Pandas, etc.)

### Documentation
- Added prominent deprecation notice to README
- Added migration guide for DSPex users
- Clarified architectural boundaries (Snakepit = infrastructure, DSPex = domain)
- Added comprehensive architecture review documents

### Notes
- **No breaking changes** - existing code continues to work with deprecation warnings
- Core Snakepit functionality unaffected
- Non-DSPy users unaffected
- Deprecation period: 3-6 months before removal in v0.5.0

---

## [0.4.2] - 2025-10-07

### Fixed
- **DETS accumulation bug** - Fixed ProcessRegistry indefinite growth (1994+ stale entries cleaned up)
- **Session creation race condition** - Implemented atomic session creation with `:ets.insert_new` to eliminate concurrent initialization errors
- **Resource cleanup race condition** - Fixed `wait_for_worker_cleanup` to check actual resources (port availability + registry cleanup) instead of dead Elixir PID
- **Test cleanup race condition** - Added proper error handling in test teardown for already-stopped workers
- **ExDoc warnings** - Fixed documentation references by moving INSTALLATION.md to guides/ and adding to ExDoc extras

### Changed
- **ApplicationCleanup simplified** - Simplified implementation, changed to emergency-only handler with telemetry
- **Worker.Starter documentation** - Added comprehensive moduledoc with ADR-001 link explaining external process management rationale
- **DETS cleanup optimization** - Changed from O(n) per-PID syscalls to O(1) beam_run_id-based cleanup
- **Process.alive? filter removed** - Eliminated redundant check (Supervisor.which_children already returns alive children only)

### Added
- **ADR-001** - Architecture Decision Record documenting Worker.Starter supervision pattern rationale
- **External Process Supervision Design** - Comprehensive 1074-line design document covering multi-mode architecture
- **Issue #2 critical review** - Detailed analysis addressing all community feedback concerns
- **Performance benchmarks** - Added baseline benchmarks showing 1400-1500 ops/sec sustained throughput
- **Telemetry in ApplicationCleanup** - Added events for tracking orphan detection and emergency cleanup

### Removed
- **Dead code cleanup** - Removed unused/aspirational code:
  - Snakepit.Python module (referenced non-existent adapter)
  - GRPCBridge adapter (never used)
  - Dead Python adapters (dspy_streaming.py, enhanced.py, grpc_streaming.py)
  - Redundant helper functions in ApplicationCleanup
  - Catch-all rescue clauses (follows "let it crash" philosophy)

### Performance
- 100 workers initialize in ~3 seconds (unchanged)
- 1400-1500 operations/second sustained (maintained)
- DETS cleanup now O(1) vs O(n) (significant improvement for large process counts)

### Documentation
- Complete installation guide with platform-specific instructions (Ubuntu, macOS, WSL, Docker)
- Marked working vs WIP examples clearly (3 working, 6 aspirational)
- Added comprehensive analysis documents (150KB total)

### Testing
- All 139/139 tests passing ✅
- No orphaned processes ✅
- Clean shutdown behavior validated ✅

## [0.4.1] - 2025-07-24

### Added
- **New `process_text` tool** - Text processing capabilities with upper, lower, reverse, and length operations
- **New `get_stats` tool** - Real-time adapter and system monitoring with memory usage, CPU usage, and system information
- **Enhanced ShowcaseAdapter** - Added missing tools (adapter_info, echo, process_text, get_stats) for complete tool bridge demonstration

### Fixed
- **gRPC tool registration issues** - Resolved async/sync mismatch causing UnaryUnaryCall objects to be returned instead of actual responses
- **Missing tool errors** - Fixed "Unknown tool: adapter_info" and "Unknown tool: echo" errors by implementing missing @tool decorated methods
- **Automatic session initialization** - Fixed "Failed to register tools: not_found" error by automatically creating sessions before tool registration
- **Remote tool dispatch** - Implemented complete bidirectional tool execution between Elixir BridgeServer and Python workers
- **Async/sync compatibility** - Added proper handling for both sync and async gRPC stubs with fallback logic for UnaryUnaryCall objects

### Changed
- **BridgeServer enhancement** - Added remote tool execution capabilities with worker port lookup and gRPC forwarding
- **Python gRPC server** - Enhanced with automatic session initialization before tool registration
- **ShowcaseAdapter refactoring** - Expanded tool set to demonstrate full bidirectional tool bridge capabilities

## [0.4.0] - 2025-07-23

### Added
- Complete gRPC bridge implementation with full bidirectional tool execution
- Tool bridge streaming support for efficient real-time communication
- Variables feature with type system (string, integer, float, boolean, choice, tensor, embedding)
- Comprehensive process management and cleanup system
- Process registry with enhanced tracking and orphan detection
- SessionStore with TTL support and automatic expiration
- BridgeServer implementation for gRPC protocol
- StreamHandler for managing gRPC streaming responses
- Telemetry module for comprehensive metrics and monitoring
- MockGRPCWorker and test infrastructure improvements
- Showcase application with multiple demo scenarios
- Binary serialization support for large data (>10KB) with 5-10x performance improvement
- Automatic binary encoding with threshold detection
- Protobuf schema updates with binary fields support
- Tool registration and discovery system
- Elixir tool exposure to Python workers
- Batch variable operations for performance
- Variable watching/reactive updates support
- Heartbeat mechanism for session health monitoring

### Changed
- Major refactoring from legacy bridge system to gRPC-only architecture
- Removed all legacy bridge implementations (V1, V2, MessagePack)
- Unified all adapters to use gRPC protocol exclusively
- Worker module completely rewritten for gRPC support
- Pool module enhanced with configurable adapter support
- ProcessRegistry rewritten with improved tracking and cleanup
- Test framework upgraded with SuperTester integration
- Examples reorganized and updated for gRPC usage
- Python client library restructured as snakepit_bridge package
- Serialization module now returns 3-tuple `{:ok, any_map, binary_data}`
- Large tensors and embeddings automatically use binary encoding
- Integration tests updated to use new infrastructure

### Fixed
- Process cleanup and orphan detection issues
- Worker termination and registry cleanup
- Module redefinition warnings in test environment
- SessionStore TTL validation and expiration timing
- Mock adapter message handling
- Integration test pool timeouts and shutdown
- GitHub Actions deprecation warnings
- Elixir version compatibility in integration tests

### Removed
- All legacy bridge implementations (generic_python.ex, generic_python_v2.ex, etc.)
- MessagePack protocol support (moved to gRPC exclusively)
- Old Python bridge scripts (generic_bridge.py, enhanced_bridge.py)
- Legacy session_context.py implementation
- V1/V2 adapter pattern in favor of unified gRPC approach

## [0.3.3] - 2025-07-20

### Added
- Support for custom adapter arguments in gRPC adapter via pool configuration
- Enhanced Python API commands (call, store, retrieve, list_stored, delete_stored) in gRPC adapter
- Dynamic command validation based on adapter type in gRPC adapter

### Changed
- GRPCPython adapter now accepts custom adapter arguments through pool_config.adapter_args
- Improved supported_commands/0 to dynamically include commands based on the adapter in use

### Fixed
- gRPC adapter now properly supports third-party Python adapters like DSPy integration

## [0.3.2] - 2025-07-20

### Fixed
- Added missing files to the repository

## [0.3.1] - 2025-07-20

### Changed
- Merged MessagePack optimizations into main codebase
- Unified documentation for gRPC and MessagePack features
- Set GenericPythonV2 as default adapter with auto-negotiation

## [0.3.0] - 2025-07-20

### Added
- Complete gRPC bridge implementation with streaming support
- MessagePack serialization protocol support
- Comprehensive gRPC integration documentation and setup guides
- Enhanced bridge documentation and examples

### Changed
- Deprecated V1 Python bridge in favor of V2 architecture
- Updated demo implementations to use V2 Python bridge
- Improved gRPC streaming bridge implementation
- Enhanced debugging capabilities and cleanup

### Fixed
- Resolved init/1 blocking issues in V2 Python bridge
- General debugging improvements and code cleanup

## [0.2.1] - 2025-07-20

### Fixed
- Eliminated "unexpected message" logs in Pool module by properly handling Task completion messages from `Task.Supervisor.async_nolink`

## [0.2.0] - 2025-07-19

### Added
- Complete Enhanced Python Bridge V2 Extension implementation
- Built-in type support for Python Bridge V2
- Test rework specifications and improved testing infrastructure
- Commercial refactoring recommendations documentation

### Changed
- Enhanced Python Bridge V2 with improved architecture and session management
- Improved debugging capabilities for V2 examples
- Better error handling and robustness in Python Bridge

### Fixed
- Bug fixes in Enhanced Python Bridge examples
- Data science example debugging improvements
- General cleanup and code improvements

## [0.1.2] - 2025-07-18

### Added
- Python Bridge V2 with improved architecture and session management
- Generalized Python bridge implementation
- Enhanced session management capabilities

### Changed
- Major architectural improvements to Python bridge
- Better integration with external Python processes

## [0.1.1] - 2025-07-18

### Added
- DIAGS.md with comprehensive Mermaid architecture diagrams
- Elixir-themed styling and proper subgraph format for diagrams
- Logo support to ExDoc and hex package
- Mermaid diagram support in documentation

### Changed
- Updated configuration to include assets and documentation
- Improved documentation structure and visual presentation

### Fixed
- README logo path for hex docs
- Asset organization (moved img/ to assets/)

## [0.1.0] - 2025-07-18

### Added
- Initial release of Snakepit
- High-performance pooling system for external processes
- Session-based execution with worker affinity
- Built-in adapters for Python and JavaScript/Node.js
- Comprehensive session management with ETS storage
- Telemetry and monitoring support
- Graceful shutdown and process cleanup
- Extensive documentation and examples

### Features
- Lightning-fast concurrent worker initialization (1000x faster than sequential)
- Session affinity for stateful operations
- Built on OTP primitives (DynamicSupervisor, Registry, GenServer)
- Adapter pattern for any external language/runtime
- Production-ready with health checks and error handling
- Configurable pool sizes and timeouts
- Built-in bridge scripts for Python and JavaScript

[Unreleased]: https://github.com/nshkrdotcom/snakepit/compare/v0.8.5...HEAD
[0.8.5]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.5
[0.8.4]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.4
[0.8.3]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.3
[0.8.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.2
[0.8.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.1
[0.8.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.8.0
[0.7.7]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.7
[0.7.6]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.6
[0.7.5]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.5
[0.7.4]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.4
[0.7.3]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.3
[0.7.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.2
[0.7.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.1
[0.7.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.7.0
[0.6.11]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.6.11
[0.6.10]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.6.10
[0.6.9]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.6.9
[0.6.8]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.6.8
[0.6.7]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.6.7
[0.5.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.5.0
[0.4.3]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.4.3
[0.4.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.4.2
[0.4.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.4.1
[0.4.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.4.0
[0.3.3]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.3.3
[0.3.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.3.2
[0.3.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.3.1
[0.3.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.2.0
[0.1.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.2
[0.1.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.0
