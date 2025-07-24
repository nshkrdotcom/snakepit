# Snakepit Architecture

## Overview

Snakepit is a high-performance Python bridge for Elixir that enables seamless execution of Python code from Elixir applications. It uses a pure gRPC-based architecture with stateless Python workers and centralized session management in Elixir.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Elixir Application                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐     ┌──────────────────┐    ┌────────────────┐  │
│  │    Pool      │────▶│ WorkerSupervisor │───▶│ Worker.Starter │  │
│  │  (GenServer) │     │ (DynamicSupervisor)   │  (Supervisor)  │  │
│  └──────────────┘     └──────────────────┘    └────────────────┘  │
│         │                                               │           │
│         │                                               ▼           │
│         │              ┌────────────────┐       ┌──────────────┐  │
│         │              │  SessionStore  │       │  GRPCWorker  │  │
│         └─────────────▶│  (GenServer)   │       │ (GenServer)  │  │
│                        │  + ETS Table   │       └──────────────┘  │
│                        └────────────────┘              │           │
│                                                         │ gRPC      │
└─────────────────────────────────────────────────────────┼───────────┘
                                                          │
┌─────────────────────────────────────────────────────────┼───────────┐
│                        Python Worker                    │           │
│                                                         ▼           │
│  ┌──────────────────┐    ┌──────────────────┐  ┌──────────────┐  │
│  │  grpc_server.py  │────│ SessionContext   │──│    Types &    │  │
│  │ (gRPC Service)   │    │ (Cache + Client) │  │ Serialization │  │
│  └──────────────────┘    └──────────────────┘  └──────────────┘  │
│           │                                                         │
│           ▼                                                         │
│  ┌──────────────────┐    ┌──────────────────┐                    │
│  │  User Adapter    │────│   User Tools     │                    │
│  │  (BaseAdapter)   │    │  (Custom Code)   │                    │
│  └──────────────────┘    └──────────────────┘                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Key Components

### Elixir Side

#### Pool (`lib/snakepit/pool/pool.ex`)
- **Purpose**: Manages a pool of Python workers for concurrent execution
- **Design**: GenServer that maintains available/busy worker sets and a request queue
- **Features**:
  - Concurrent worker startup
  - Session affinity (routes session requests to same worker when possible)
  - Automatic request queueing when all workers are busy
  - Non-blocking async execution using `Task.Supervisor`

#### WorkerSupervisor (`lib/snakepit/pool/worker_supervisor.ex`)
- **Purpose**: DynamicSupervisor for managing worker lifecycle
- **Design**: Starts Worker.Starter processes which in turn manage actual workers
- **Features**: Provides clean separation between supervision and worker logic

#### Worker.Starter (`lib/snakepit/pool/worker_starter.ex`)
- **Purpose**: Implements the "Permanent Wrapper" pattern for automatic worker restarts
- **Design**: A permanent supervisor that manages a transient worker
- **Features**:
  - Automatic restart of crashed workers without Pool intervention
  - Clean shutdown during application termination
  - Decouples Pool from worker replacement logic

#### GRPCWorker (`lib/snakepit/grpc_worker.ex`)
- **Purpose**: Manages a single Python worker process
- **Design**: GenServer that spawns and communicates with Python via gRPC
- **Features**:
  - Port-based process management
  - Health checking
  - Automatic reconnection
  - Request timeout handling
  - Statistics tracking

#### SessionStore (`lib/snakepit/bridge/session_store.ex`)
- **Purpose**: Centralized session and variable management
- **Design**: GenServer backed by ETS table for high-performance concurrent access
- **Features**:
  - TTL-based session expiration
  - Type-safe variable storage
  - Atomic operations
  - High-performance cleanup using ETS `select_delete`
  - Read-concurrency optimization

### Python Side

#### grpc_server.py (`priv/python/grpc_server.py`)
- **Purpose**: Main gRPC service implementation
- **Design**: Stateless server that delegates to adapters and manages sessions
- **Features**:
  - Unified protocol supporting both simple execution and session-based operations
  - Tool registration and execution
  - Streaming support
  - Comprehensive error handling

#### SessionContext (`priv/python/snakepit_bridge/session_context.py`)
- **Purpose**: Client-side session state with intelligent caching
- **Design**: Thread-safe context manager with TTL-based cache
- **Features**:
  - Local variable cache to reduce gRPC round-trips
  - Automatic cache invalidation on TTL expiry
  - Lazy loading of variables
  - Batch operations support

#### Types & Serialization
- **Purpose**: Consistent type system across Elixir and Python
- **Design**: Centralized modules for type conversion and validation
- **Features**:
  - Support for basic types (integer, float, string, boolean)
  - Complex types (list, map, embedding, tensor)
  - Special value handling (NaN, Infinity)
  - Binary data optimization

## Design Principles

### 1. Stateless Python Workers
Python workers are completely stateless. All persistent state is managed by the Elixir SessionStore. This enables:
- Easy horizontal scaling
- Crash resilience
- Simple worker replacement
- No state synchronization issues

### 2. Centralized State Management
The SessionStore in Elixir is the single source of truth for all session state:
- Variables are stored with type information
- Sessions have TTL-based expiration
- All operations are atomic
- High concurrency via ETS

### 3. Performance Optimization
- **ETS for Storage**: Read-concurrency optimized ETS tables for session data
- **Client-side Caching**: Python SessionContext caches variables locally
- **Batch Operations**: Support for bulk variable operations
- **Binary Protocol**: gRPC with protobuf for efficient serialization

### 4. Fault Tolerance
- **Supervision Tree**: Proper OTP supervision at every level
- **Process Monitoring**: Multiple layers of process monitoring
- **Automatic Cleanup**: ApplicationCleanup prevents orphaned processes
- **Health Checks**: Periodic health monitoring of workers

## Protocol Specification

The system uses a unified gRPC protocol defined in `priv/proto/snakepit_bridge.proto`:

### Core Services
- **Execute**: Simple command execution
- **ExecuteStream**: Streaming command execution
- **Tool Operations**: RegisterTool, ListTools, UnregisterTool
- **Session Operations**: InitializeSession, CleanupSession
- **Variable Operations**: RegisterVariable, GetVariable, SetVariable, etc.
- **Health & Info**: Health checks and system information

### Message Flow
1. Client calls Pool with request
2. Pool assigns available worker (preferring session affinity)
3. Request forwarded to GRPCWorker
4. GRPCWorker makes gRPC call to Python
5. Python executes via adapter/tools
6. For variables: Python may call back to Elixir SessionStore
7. Response returned through the chain

## Architecture Evolution

As of v0.4.0, Snakepit uses a unified gRPC-only architecture that provides:
- **Stateless Python workers** with centralized SessionStore for state management
- **Binary gRPC protocol** with protobuf for efficient communication
- **Intelligent routing** with session affinity and multi-level caching
- **Native streaming support** for real-time progress updates
- **Bidirectional tool execution** between Elixir and Python

## Binary Serialization

### Overview

The architecture includes automatic binary serialization for efficient handling of large numerical data:

- **Threshold-based**: Automatically switches to binary encoding for data > 10KB
- **Type-aware**: Optimized for `tensor` and `embedding` types
- **Transparent**: No API changes required - works automatically
- **Protocol**: Uses Erlang Term Format (ETF) on Elixir side, Python pickle on Python side

### Implementation Details

1. **Detection**: `Serialization.should_use_binary?/2` checks data size
2. **Encoding**: 
   - Small data: JSON via `encode_as_json/2`
   - Large data: Binary via `encode_with_binary/2`
3. **Transport**: Binary data travels in separate protobuf fields
4. **Decoding**: Automatic detection of binary format via type URL suffix

### Performance Impact

- **10x faster** serialization for large tensors
- **5x reduction** in message size
- **Zero overhead** for small data (still uses JSON)

## Future Enhancements

The architecture is designed to support future features:
- **Distributed Sessions**: SessionStore could be backed by distributed ETS/Mnesia
- **Multi-node Support**: Workers could run on different nodes
- **Advanced Caching**: Redis-backed caching for large datasets
- **Metrics & Tracing**: OpenTelemetry integration end-to-end
- **Tool Marketplace**: Dynamic tool loading from external sources
- **Compression**: Optional compression for binary data
- **Custom Serializers**: Pluggable serialization formats