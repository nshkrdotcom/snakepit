# TODO Items for Issue Tracking

This document lists TODO items found in the codebase that should be converted to tracked issues in your project management system.

## High Priority

### 1. Implement Force Flag for Session Cleanup
- **Location**: `lib/snakepit/grpc/bridge_server.ex:81`
- **Context**: The `CleanupSession` RPC handler currently ignores the `force` flag
- **Task**: Implement force cleanup logic in SessionStore that bypasses normal cleanup constraints
- **Impact**: Required for full gRPC API compliance

### 2. Implement Remaining gRPC Handlers
- **Location**: `lib/snakepit/grpc/bridge_server.ex:425`
- **Context**: Several gRPC service methods are not yet implemented
- **Task**: Implement the following handlers:
  - `ImportVariables` - Bulk variable import
  - `ExportVariables` - Bulk variable export
  - `WatchVariable` - Real-time variable change notifications
  - `OptimizeVariables` - Variable optimization based on usage patterns
- **Impact**: These are advanced features that would enhance the API

## Medium Priority

### 3. Stage 3: Observer Pattern for Variables
- **Location**: `lib/snakepit/bridge/session_store.ex:799`
- **Context**: Variable updates should notify observers for reactive programming
- **Task**: Implement observer/subscription mechanism for variable changes
- **Impact**: Enables reactive programming patterns and real-time updates

### 4. Stage 3: Implement Variable Caching
- **Location**: `lib/snakepit/grpc/bridge_server.ex:188`
- **Context**: The `GetVariableHistory` handler mentions future caching support
- **Task**: Implement caching layer for frequently accessed variables
- **Impact**: Performance optimization for read-heavy workloads

## Low Priority

### 5. Python Telemetry Implementation
- **Context**: Python side lacks telemetry for cache hits/misses and tool execution
- **Task**: Add telemetry emissions in:
  - `SessionContext` for cache hit/miss rates
  - Tool execution timing in adapters
  - gRPC call metrics
- **Impact**: Better observability and performance monitoring

## Notes

- All Stage 3 items are part of a future enhancement phase
- The force flag and remaining handlers should be prioritized for API completeness
- Telemetry can be added incrementally without breaking changes