# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.2.0
[0.1.2]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.2
[0.1.1]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/snakepit/releases/tag/v0.1.0