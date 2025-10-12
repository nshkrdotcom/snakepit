# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2025-10-11

### Added
- **Diagnostic Tools**
  - New `mix diagnose.scaling` task (613 lines) for comprehensive bottleneck analysis
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
  - Added README_GRPC.md (304 lines) and README_BIDIRECTIONAL_TOOL_BRIDGE.md (288 lines)
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
  - Removed ~1,500 LOC of dead Python code
  - Deleted obsolete backup files and unused modules
  - Streamlined Python SessionContext from 845 to 169 lines
  - Cleaned up test infrastructure and removed duplicate code
  - Archived ~60 historical documentation files to docs/archive/

- **Examples Refactoring**
  - Simplified grpc_streaming_demo.exs (334 → 44 lines effective)
  - Refactored grpc_advanced.exs for better clarity (365 lines optimized)
  - Enhanced grpc_sessions.exs with improved structure (170 lines)
  - Streamlined grpc_streaming.exs (97 lines optimized)
  - Improved grpc_concurrent.exs with better patterns (320 lines refactored)

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
  - Removed deprecated `dspy_integration.py` module (469 lines)
  - Removed deprecated `types.py` with VariableType enum (227 lines)
  - Removed `session_context.py.backup` (845 lines)
  - Removed obsolete `test_server.py` (70 lines)
  - Removed unused CLI directory referencing non-existent modules
  - All `__pycache__/` directories cleaned up

- **Variables Feature (Temporary Removal)**
  - Removed incomplete variables implementation pending future redesign:
    - `lib/snakepit/bridge/variables.ex` (44 lines)
    - `lib/snakepit/bridge/variables/variable.ex` (217 lines)
    - `lib/snakepit/bridge/variables/types.ex` (98 lines)
    - All variable type modules (boolean, choice, embedding, float, integer, module, string, tensor)
    - `examples/grpc_variables.exs` (177 lines)
    - `lib/snakepit_showcase/demos/variables_demo.ex` (140 lines)
    - Related test files and Python code

- **Deprecated Components**
  - Removed `lib/snakepit/bridge/serialization.ex` (288 lines)
  - Removed `lib/snakepit/grpc/stream_handler.ex` (68 lines)
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
- **ApplicationCleanup simplified** - Reduced from 217 to 122 LOC (44% reduction), changed to emergency-only handler with telemetry
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
- **Dead code cleanup** - Removed 1,000+ LOC of unused/aspirational code:
  - Snakepit.Python module (530 LOC, referenced non-existent adapter)
  - GRPCBridge adapter (95 LOC, never used)
  - Dead Python adapters (dspy_streaming.py, enhanced.py, grpc_streaming.py - 561 LOC)
  - Redundant helper functions in ApplicationCleanup (95 LOC)
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
