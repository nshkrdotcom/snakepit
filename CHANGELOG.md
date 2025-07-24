# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
