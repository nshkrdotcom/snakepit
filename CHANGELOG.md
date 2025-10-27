# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.6] - 2025-10-27

### Added
- Configurable session/program quotas now surface tagged errors when limits are exceeded, with regression coverage in `test/unit/bridge/session_store_test.exs`.
- Introduced a logger redaction helper so adapters and bridge code can log sensitive inputs safely (`test/unit/logger/redaction_test.exs`).

### Changed
- `Snakepit.GRPC.BridgeServer` reuses worker-owned gRPC channels and only dials a disposable connection when the worker has not yet published one; fallbacks are closed after each invocation.
- gRPC streaming helpers document and enforce the JSON-plus-metadata chunk envelope, clarifying `_metadata` and `raw_data_base64` handling.
- Worker startup handshake waits for the negotiated gRPC port before publishing worker metadata, eliminating transient routing failures during boot.

### Fixed
- `Snakepit.GRPCWorker` persists the OS-assigned port discovered during startup so BridgeServer never receives `0` when routing requests (`test/unit/grpc/grpc_worker_ephemeral_port_test.exs`).
- Parameter decoding now rejects malformed protobuf payloads with descriptive `{:invalid_parameter, key, reason}` errors, preventing unexpected crashes (`test/snakepit/grpc/bridge_server_test.exs`).
- Process registry ETS tables are `:protected` and DETS handles remain private, guarding against external mutation attempts (`test/unit/pool/process_registry_security_test.exs`).

### Documentation
- Refreshed README, gRPC guides (including the streaming and quick reference docs), and testing notes to cover port persistence, channel reuse, quota enforcement, DETS/ETS protections, streaming payload envelopes, logging redaction guardrails, and the expanded regression suite.

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
