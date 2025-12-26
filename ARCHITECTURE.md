# Snakepit Architecture

> System Architecture for Snakepit v0.7.4

## Overview

Snakepit is a high-performance process pooler and session manager that bridges Elixir and external language runtimes (primarily Python) via gRPC. The architecture prioritizes:

- **Fault isolation**: Each worker runs in a separate OS process
- **High throughput**: Concurrent worker initialization and request distribution
- **Observability**: Comprehensive telemetry with OpenTelemetry integration
- **Clean lifecycle**: Automatic orphan cleanup and graceful shutdown

## Core Components

### 1. Application Supervisor Tree

```
Snakepit.Supervisor (one_for_one)
├── Snakepit.Bridge.SessionStore      # Session management (ETS)
├── Snakepit.Bridge.ToolRegistry      # Tool registration (ETS)
├── Snakepit.GRPC.Server.Supervisor   # gRPC server for Python callbacks
├── Snakepit.GRPC.Client.Supervisor   # gRPC client connections
├── Snakepit.Pool.Registry            # Worker registration (ETS)
├── Snakepit.Pool.ProcessRegistry     # External PID tracking (ETS/DETS)
├── Snakepit.Pool.Worker.StarterRegistry  # Starter supervisor tracking
├── Snakepit.Telemetry.GrpcStream     # Bidirectional telemetry streams
├── Snakepit.Pool                     # Pool GenServer
│   └── Snakepit.Pool.WorkerSupervisor (DynamicSupervisor)
│       └── Snakepit.Pool.Worker.Starter (per worker, permanent)
│           └── Snakepit.GRPCWorker (transient)
└── Snakepit.Pool.ApplicationCleanup  # Shutdown guarantees
```

### 2. Pool System (`lib/snakepit/pool/`)

The pool manages worker availability and request distribution.

**Key Files:**
- `pool.ex` - Core GenServer (~1500 lines) handling:
  - Worker availability tracking via MapSet
  - Request queuing with priority support
  - Session affinity cache
  - Capacity-aware scheduling (`:pool`, `:profile`, `:hybrid` strategies)
  - Statistics and metrics
  - Crash barrier coordination for tainting and retries

**Pool State:**
```elixir
%{
  name: :default,
  size: 10,
  workers: MapSet.t(),        # All worker IDs
  available: MapSet.t(),      # Idle worker IDs
  worker_loads: %{},          # Per-worker request counts
  worker_capacities: %{},     # Per-worker thread capacity
  request_queue: %{},         # Priority-keyed pending requests
  stats: %{...},
  initialized: boolean()
}
```

### 3. Worker Lifecycle

Workers follow a "Permanent Wrapper" supervision pattern:

```
Pool.WorkerSupervisor (DynamicSupervisor)
└── Pool.Worker.Starter (Supervisor, :permanent)
    └── GRPCWorker (GenServer, :transient)
```

**Why this pattern?**
- Starter is permanent: always restarts after crash
- GRPCWorker is transient: only restarts on abnormal exit
- Pool tracks availability, not restarts
- Decouples scheduling from lifecycle management

**Worker Startup Sequence:**
1. Pool requests `WorkerSupervisor.start_worker(worker_id, config)`
2. DynamicSupervisor starts a `Worker.Starter` for this worker
3. Starter spawns `GRPCWorker` as its child
4. GRPCWorker opens OS port to spawn Python process
5. Python binds to ephemeral port, prints `GRPC_READY:{port}`
6. GRPCWorker connects to Python's gRPC server
7. Connection verified with ping, worker registered as available

### Crash Barrier

Crash barrier logic is centralized in `Snakepit.CrashBarrier` and invoked by the pool
when a worker exits abnormally. It classifies crash reasons, taints unstable workers,
and retries idempotent calls when configured.

Key pieces:
- `Snakepit.CrashBarrier` for policy + classification
- `Snakepit.Worker.TaintRegistry` for taint tracking and expiry
- `pool.ex` retry hooks honoring `idempotent` payloads

### 4. gRPC Bridge (`lib/snakepit/grpc/`)

Bidirectional communication between Elixir and Python.

**Server (BridgeServer.ex):**
- Receives callbacks from Python workers
- Implements: `ping`, `execute_elixir_tool`, `register_tools`, `heartbeat`
- Routes tool calls to registered Elixir handlers

**Client (ClientImpl.ex):**
- Connects to Python worker's gRPC server
- Methods: `connect`, `ping`, `initialize_session`, `execute_tool`, `execute_streaming_tool`
- Automatic reconnection with exponential backoff
- Runtime metadata attached to requests (Python runtime hash, version, platform)

**GRPCWorker (grpc_worker.ex):**
- GenServer managing a single Python process
- Handles request/response and streaming
- Monitors Python process via port
- Emits telemetry events for observability

**Runtime Contract:**
- `kwargs` (always present, may be empty)
- `call_type` for class/method/attr dispatch
- `idempotent` for crash barrier retries
- `payload_version` for schema evolution

### 5. Session System (`lib/snakepit/bridge/`)

**SessionStore:**
- ETS-backed storage with TTL expiration
- Automatic cleanup every 60 seconds
- Default TTL: 3600 seconds (1 hour)
- Max sessions: 10,000

**Session Structure:**
```elixir
%Session{
  id: "session_123",
  created_at: timestamp,
  last_accessed: timestamp,
  last_worker_id: "worker_1",  # Affinity tracking
  ttl: 3600,
  programs: %{},               # Session-scoped data
  metadata: %{}
}
```

**ToolRegistry:**
- Registers both Elixir and Python tools
- Tool types: `:local` (Elixir) or `:remote` (Python)
- Validates tool names and metadata size

### 6. Worker Profiles (`lib/snakepit/worker_profile/`)

Two isolation strategies for different workloads:

**Process Profile (Default):**
- One Python process per worker
- Full process isolation
- Capacity: 1 concurrent request per worker
- Best for: I/O-bound tasks, stability-critical workloads

**Thread Profile (Python 3.13+):**
- ThreadPoolExecutor within each Python process
- Shared memory between threads
- Capacity: `threads_per_worker` concurrent requests
- Best for: CPU-bound tasks with shared data, memory-constrained systems

### 7. Telemetry System (`lib/snakepit/telemetry/`)

Three-layer event architecture:

**Layer 1: Infrastructure (Elixir-originated)**
- Pool: `[:snakepit, :pool, :initialized]`, `[:snakepit, :pool, :worker, :spawned]`
- Queue: `[:snakepit, :pool, :queue, :enqueued]`, `[:snakepit, :pool, :queue, :timeout]`
- Session: `[:snakepit, :session, :created]`, `[:snakepit, :session, :affinity, :assigned]`

**Layer 2: Python Execution (Folded from workers)**
- Calls: `[:snakepit, :python, :call, :start]`, `[:snakepit, :python, :call, :stop]`
- Tools: `[:snakepit, :python, :tool, :execution, :start/stop]`
- Resources: `[:snakepit, :python, :memory, :sampled]`

**Layer 3: gRPC Bridge**
- Calls: `[:snakepit, :grpc, :call, :start/stop]`
- Streams: `[:snakepit, :grpc, :stream, :opened/message/closed]`
- Connections: `[:snakepit, :grpc, :connection, :established/lost]`

**Key Modules:**
- `naming.ex` - Event catalog with atom safety validation
- `safe_metadata.ex` - Metadata sanitization to prevent atom exhaustion
- `grpc_stream.ex` - Bidirectional telemetry stream management
- `open_telemetry.ex` - OpenTelemetry integration
- `control.ex` - Runtime sampling and filtering control

### 8. Adapter System

Adapters define how to spawn external processes.

**Behavior (`lib/snakepit/adapter.ex`):**
```elixir
@callback executable_path() :: String.t()   # "python3"
@callback script_path() :: String.t()        # Path to gRPC server script
@callback script_args() :: [String.t()]      # CLI arguments
@optional_callback command_timeout(cmd, args) :: pos_integer()
```

**GRPCPython Adapter:**
- Default Python adapter
- Discovers Python: config > env > venv > system (or uv-managed runtime)
- Selects server script: process or threaded
- Configurable per-command timeouts
- Injects runtime identity into worker environment

### 9. Process Management

**ProcessRegistry:**
- Tracks: worker_id ↔ elixir_pid ↔ external_pid mapping
- Persists state to DETS for crash recovery
- Generates unique BEAM run IDs

**ProcessKiller:**
- Finds orphaned Python processes by run ID
- Graceful shutdown: SIGTERM → wait → SIGKILL
- Called during application startup and script cleanup

**ApplicationCleanup:**
- Started last in supervision tree
- Ensures all workers terminate during shutdown
- Provides hard termination guarantees

## Request Flow

### Simple Execution

```
1. Snakepit.execute("cmd", args)
2. Pool.execute via GenServer.call
3. Pool checks :available set for idle worker
4. If none available, enqueue to :request_queue
5. Worker found → GRPCWorker.execute
6. gRPC call to Python worker
7. Python adapter executes tool
8. Result returned through gRPC
9. Worker returned to :available set
10. Pool dequeues pending requests
```

### Streaming Execution

```
1. Snakepit.execute_stream("cmd", args, callback)
2. Pool.checkout_worker → worker_pid
3. GRPCWorker.execute_stream opens bidirectional stream
4. Python sends ToolChunk messages
5. Each chunk passed to callback function
6. Stream closes when is_final=true
7. Pool.checkin_worker returns worker to available
```

### Session-Based Execution

```
1. Snakepit.execute_in_session("session_id", "cmd", args)
2. SessionStore checks affinity cache for last_worker_id
3. If last worker available, use it; otherwise any available
4. Execute as normal
5. Update session.last_worker_id for future affinity
```

## Configuration

### Single Pool (Simple)
```elixir
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "my_adapter"],
  pool_size: 10
```

### Multi-Pool (Advanced)
```elixir
config :snakepit,
  pooling_enabled: true,
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 10,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "general_adapter"],
      worker_ttl: {3600, :seconds},
      worker_max_requests: 1000
    },
    %{
      name: :compute,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 8,
      adapter_args: ["--adapter", "ml_adapter"],
      capacity_strategy: :profile
    }
  ]
```

## Python Side

**gRPC Servers (`priv/python/`):**
- `grpc_server.py` - Single-process server
- `grpc_server_threaded.py` - Multi-threaded server with ThreadPoolExecutor

**Bridge Package (`priv/python/snakepit_bridge/`):**
- `base_adapter.py` - Base class with `@tool` decorator
- `session_context.py` - Session management, Elixir tool calls
- `serialization.py` - JSON/binary serialization with orjson
- `zero_copy.py` - DLPack/Arrow handle support
- `heartbeat.py` - Health check client
- `telemetry/` - Event emission and streaming

## Design Principles

1. **Stateless Python**: All state lives in Elixir; Python workers are replaceable
2. **Layered Supervision**: Crash isolation at every level
3. **ETS for Speed**: O(1) lookups for hot paths (registry, sessions)
4. **Ephemeral Ports**: OS-assigned ports eliminate collision races
5. **Exponential Backoff**: Prevents thundering herd on reconnection
6. **Correlation IDs**: Cross-language request tracing
7. **Graceful Degradation**: Workers can be recycled without service interruption
8. **Zero-Copy When Available**: DLPack/Arrow handle paths avoid extra copies, with
   safe fallbacks to serialized payloads

## Performance Characteristics

- **Worker Startup**: ~500ms per worker (Python + gRPC connection)
- **Request Latency**: ~10-50ms (gRPC overhead minimal)
- **Memory**: ~1KB per OTP process + Python process memory
- **Scalability**: Tested with 250+ workers
- **Telemetry Overhead**: <10μs per event

## Error Handling

**Error Categories:**
- `:pool_error` - No workers, queue full, timeout
- `:worker_error` - Startup, connection, execution failures
- `:validation_error` - Invalid input
- `:timeout` - Operation exceeded time limit
- `:grpc_error` - Communication failures

## Prime Runtime Enhancements

Snakepit 0.7.4 adds runtime capabilities for ML workloads:

- **Zero-copy interop** via `Snakepit.ZeroCopy` and `Snakepit.ZeroCopyRef` (DLPack + Arrow).
- **Crash barrier** with worker tainting, idempotent retry policy, and crash telemetry.
- **Hermetic Python runtime** with uv-managed interpreter selection and runtime identity metadata.
- **Exception translation** mapping Python exceptions to Elixir structs in `Snakepit.Error.*`.

**Timeout Hierarchy:**
| Operation | Default | Configurable |
|-----------|---------|--------------|
| Command execution | 30s | Per-command via adapter |
| Queue wait | 5s | `queue_timeout` |
| Worker startup | 10s | `worker_startup_timeout` |
| Pool initialization | 15s | `run_as_script` timeout option |

## See Also

- [DIAGRAMS.md](DIAGRAMS.md) - Visual architecture diagrams
- [README_GRPC.md](README_GRPC.md) - gRPC streaming details
- [TELEMETRY.md](TELEMETRY.md) - Complete event catalog
- [README_PROCESS_MANAGEMENT.md](README_PROCESS_MANAGEMENT.md) - Lifecycle management
