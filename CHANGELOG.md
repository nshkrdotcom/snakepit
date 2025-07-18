# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.0