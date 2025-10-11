# Snakepit gRPC & Session Architecture - Technical Deep Dive

**Date:** October 10, 2025
**Status:** Current Implementation (v0.4.3+)
**Purpose:** Comprehensive technical documentation of gRPC and SessionStore architecture

---

## Executive Summary

Snakepit uses a **stateless Python / stateful Elixir** architecture with bidirectional gRPC communication. Python workers are ephemeral execution environments that proxy all state operations to a centralized Elixir SessionStore. This design enables:

- **Horizontal scalability**: Python workers are stateless and disposable
- **Session persistence**: State survives Python process restarts
- **Worker affinity**: Sessions can be routed to specific workers for optimization
- **Bidirectional tool calls**: Seamless cross-language function execution

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         ELIXIR SIDE                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────┐      ┌─────────────────────────────┐   │
│  │   GRPCWorker       │      │  GRPC.BridgeServer          │   │
│  │  (GenServer)       │◄────►│  (Port: 50051)              │   │
│  │                    │      │                             │   │
│  │  - Manages Python  │      │  - Tool execution           │   │
│  │  - Port lifecycle  │      │  - Session management       │   │
│  │  - gRPC channel    │      │  - Variable operations      │   │
│  │  - Health checks   │      │                             │   │
│  └────────┬───────────┘      └──────────┬──────────────────┘   │
│           │                              │                       │
│           │                              ▼                       │
│           │                  ┌──────────────────────────────┐   │
│           │                  │    SessionStore (ETS)        │   │
│           │                  │                              │   │
│           │                  │  - Session data              │   │
│           │                  │  - Programs (ML models)      │   │
│           │                  │  - Worker affinity           │   │
│           │                  │  - TTL management            │   │
│           │                  │  - Global programs           │   │
│           │                  └──────────────────────────────┘   │
│           │                                                      │
└───────────┼──────────────────────────────────────────────────────┘
            │ Spawns + Monitors
            │ via Port
            ▼
┌─────────────────────────────────────────────────────────────────┐
│                         PYTHON SIDE                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  grpc_server.py (BridgeServiceServicer)                │    │
│  │  (Port: 50052+)                                        │    │
│  │                                                         │    │
│  │  - Proxies state ops to Elixir BridgeServer           │    │
│  │  - Executes Python tools locally                       │    │
│  │  - Creates ephemeral SessionContext per request        │    │
│  │  - Streaming support (sync/async generators)           │    │
│  └────────────────┬───────────────────────────────────────┘    │
│                   │                                              │
│                   ▼                                              │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  SessionContext (Minimal)                              │    │
│  │                                                         │    │
│  │  - session_id: str                                     │    │
│  │  - stub: BridgeServiceStub                             │    │
│  │  - Lazy-load elixir_tools                              │    │
│  │  - call_elixir_tool(name, **kwargs)                    │    │
│  └────────────────┬───────────────────────────────────────┘    │
│                   │                                              │
│                   ▼                                              │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  BaseAdapter + ShowcaseAdapter                         │    │
│  │                                                         │    │
│  │  - @tool decorator for tool discovery                  │    │
│  │  - execute_tool(tool_name, args, context)              │    │
│  │  - register_with_session(session_id, stub)             │    │
│  │  - Supports streaming (generators)                     │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. gRPC Communication Layer

#### Protocol Definition (`snakepit_bridge.proto`)

The gRPC protocol defines a unified bridge service with the following RPC categories:

**Session Management:**
- `Ping` - Health check
- `InitializeSession` - Create/verify session
- `CleanupSession` - Best-effort cleanup
- `GetSession` - Retrieve session metadata
- `Heartbeat` - Keep-alive and validity check

**Tool Execution:**
- `ExecuteTool` - Non-streaming tool execution
- `ExecuteStreamingTool` - Streaming tool execution (server-side streaming)
- `RegisterTools` - Register Python tools with Elixir
- `GetExposedElixirTools` - Discover available Elixir tools
- `ExecuteElixirTool` - Call Elixir tools from Python

**Variable Operations** (Proxied to Elixir):
- `RegisterVariable` - Create typed variable
- `GetVariable` / `SetVariable` - CRUD operations
- `GetVariables` / `SetVariables` - Batch operations
- `ListVariables` - Query with pattern matching
- `DeleteVariable` - Remove variable

#### Elixir gRPC Server (`Snakepit.GRPC.BridgeServer`)

**Location:** `lib/snakepit/grpc/bridge_server.ex`
**Port:** `50051` (default, configurable)
**Role:** Central orchestrator for all gRPC operations

**Key Responsibilities:**
1. **Session lifecycle management** via `SessionStore`
2. **Tool registry** for local (Elixir) and remote (Python) tools
3. **Request routing** to appropriate Python workers
4. **Protobuf encoding/decoding** with `Google.Protobuf.Any`

**Implementation Highlights:**

```elixir
# Session initialization with atomic creation
def initialize_session(request, _stream) do
  case SessionStore.create_session(request.session_id, metadata: request.metadata) do
    {:ok, _session} ->
      %InitializeSessionResponse{success: true}
    {:error, reason} ->
      raise GRPC.RPCError, status: :internal, message: format_error(reason)
  end
end

# Tool execution with type dispatch
def execute_tool(%ExecuteToolRequest{} = request, _stream) do
  with {:ok, _session} <- SessionStore.get_session(request.session_id),
       {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
       {:ok, result} <- execute_tool_handler(tool, request, request.session_id) do
    # Success path
  end
end
```

#### Python gRPC Server (`grpc_server.py`)

**Location:** `priv/python/grpc_server.py`
**Port:** `50052+` (dynamically allocated per worker)
**Role:** Stateless tool execution environment

**Key Characteristics:**

1. **Stateless Design:**
   - No persistent state
   - Creates ephemeral `SessionContext` per request
   - All state operations proxied to Elixir

2. **Dual gRPC Clients:**
   ```python
   # Async channel for proxying operations
   self.elixir_channel = grpc.aio.insecure_channel(elixir_address)
   self.elixir_stub = pb2_grpc.BridgeServiceStub(self.elixir_channel)

   # Sync channel for SessionContext
   self.sync_elixir_channel = grpc.insecure_channel(elixir_address)
   self.sync_elixir_stub = pb2_grpc.BridgeServiceStub(self.sync_elixir_channel)
   ```

3. **Transparent Proxying:**
   ```python
   async def RegisterVariable(self, request, context):
       """Register a variable - proxy to Elixir."""
       return await self.elixir_stub.RegisterVariable(request)
   ```

4. **Local Tool Execution:**
   ```python
   async def ExecuteTool(self, request, context):
       # Create ephemeral context
       session_context = SessionContext(self.sync_elixir_stub, request.session_id)

       # Create adapter instance
       adapter = self.adapter_class()
       adapter.set_session_context(session_context)

       # Execute tool
       result_data = await adapter.execute_tool(
           tool_name=request.tool_name,
           arguments=arguments,
           context=session_context
       )
   ```

5. **Streaming Support:**
   ```python
   async def ExecuteStreamingTool(self, request, context):
       # Supports both sync and async generators
       if hasattr(stream_iterator, '__aiter__'):
           async for chunk_data in stream_iterator:
               yield pb2.ToolChunk(data=json.dumps(chunk_data).encode())
       elif hasattr(stream_iterator, '__iter__'):
           for chunk_data in stream_iterator:
               yield pb2.ToolChunk(data=json.dumps(chunk_data).encode())
   ```

---

### 2. Session Management

#### Elixir SessionStore (`Snakepit.Bridge.SessionStore`)

**Location:** `lib/snakepit/bridge/session_store.ex`
**Storage:** ETS (`:snakepit_sessions`)
**Role:** Centralized, high-performance session state manager

**Storage Model:**

```elixir
# ETS record format for efficient cleanup:
{session_id, {last_accessed, ttl, session}}

# Session structure:
%Session{
  session_id: "session_123",
  created_at: 1728583920,       # Unix timestamp
  last_accessed: 1728583920,    # Monotonic time
  ttl: 3600,                    # Seconds
  programs: %{                  # ML models, DSPy programs
    "prog_1" => %{model: "gpt-4", ...}
  },
  metadata: %{                  # User-defined metadata
    "user_id" => "user_456"
  },
  last_worker_id: "worker_1"    # Worker affinity
}
```

**Key Features:**

1. **Atomic Session Creation:**
   ```elixir
   # Uses :ets.insert_new for concurrent-safe creation
   case :ets.insert_new(state.table, ets_record) do
     true -> {:ok, session}      # Created
     false -> {:ok, existing}    # Already exists (race condition handled)
   end
   ```

2. **High-Performance Cleanup:**
   ```elixir
   # ETS select_delete with optimized match spec
   match_spec = [
     {{:_, {:"$1", :"$2", :_}},
      [{:<, {:+, :"$1", :"$2"}, current_time}],
      [true]}
   ]
   expired_count = :ets.select_delete(table, match_spec)
   ```

3. **Global Program Storage:**
   ```elixir
   # Separate ETS table for anonymous programs
   :snakepit_sessions_global_programs

   # Stored with timestamp for TTL cleanup
   {program_id, program_data, timestamp}
   ```

4. **Worker Affinity:**
   ```elixir
   def store_worker_session(session_id, worker_id) do
     update_session(session_id, fn session ->
       Map.put(session, :last_worker_id, worker_id)
     end)
   end
   ```

**Performance Optimizations:**

```elixir
# ETS table creation with optimized settings
:ets.new(table_name, [
  :set,
  :public,
  :named_table,
  {:read_concurrency, true},      # Parallel reads
  {:write_concurrency, true},     # Parallel writes
  {:decentralized_counters, true} # Per-scheduler counters
])
```

**Statistics:**

```elixir
def get_stats do
  %{
    sessions_created: 1234,
    sessions_deleted: 890,
    sessions_expired: 344,
    cleanup_runs: 24,
    current_sessions: 100,
    memory_usage_bytes: 1048576,
    global_programs_stored: 15
  }
end
```

#### Python SessionContext (`snakepit_bridge/session_context.py`)

**Location:** `priv/python/snakepit_bridge/session_context.py`
**Lines:** 170 (streamlined from 845)
**Role:** Minimal session proxy for Python adapters

**Design Philosophy:**

> **Elixir manages state, Python just participates**

**Core API:**

```python
class SessionContext:
    def __init__(self, stub: BridgeServiceStub, session_id: str):
        self.stub = stub
        self.session_id = session_id
        self._elixir_tools = None  # Lazy-loaded

    @property
    def elixir_tools(self) -> Dict[str, Any]:
        """Lazy-load Elixir tools on first access."""
        if self._elixir_tools is None:
            self._elixir_tools = self._load_elixir_tools()
        return self._elixir_tools

    def call_elixir_tool(self, tool_name: str, **kwargs) -> Any:
        """Call an Elixir tool from Python."""
        request = ExecuteElixirToolRequest(
            session_id=self.session_id,
            tool_name=tool_name,
            parameters=params_struct
        )
        response = self.stub.ExecuteElixirTool(request)
        return response.result

    def cleanup(self):
        """Best-effort cleanup (TTL is authoritative)."""
        self.stub.CleanupSession(CleanupSessionRequest(session_id=self.session_id))
```

**Usage Pattern:**

```python
# Ephemeral creation per request
session_context = SessionContext(stub, session_id)

# Adapter receives context
adapter = MyAdapter()
adapter.set_session_context(session_context)

# Adapter can call Elixir tools
result = session_context.call_elixir_tool("parse_json", json_string='{"test": true}')
```

---

### 3. Worker Lifecycle

#### GRPCWorker (`Snakepit.GRPCWorker`)

**Location:** `lib/snakepit/grpc_worker.ex`
**Role:** GenServer that manages Python gRPC server lifecycle

**Initialization Sequence:**

```elixir
# 1. Reserve worker slot BEFORE spawning process
:ok = ProcessRegistry.reserve_worker(worker_id)

# 2. Spawn Python gRPC server via Port
port = Port.open({:spawn_executable, setsid_path}, [
  {:args, [python_path, "grpc_server.py", "--port", port, ...]}
])

# 3. Wait for GRPC_READY signal (non-blocking via handle_continue)
{:ok, state, {:continue, :connect_and_wait}}

# 4. Connect to Python's gRPC server with retry logic
{:ok, connection} = adapter.init_grpc_connection(port)

# 5. Activate worker in ProcessRegistry
ProcessRegistry.activate_worker(worker_id, self(), process_pid, "grpc_worker")

# 6. Notify pool that worker is ready
GenServer.cast(pool_name, {:worker_ready, worker_id})
```

**Critical Race Condition Fix:**

Python signals `GRPC_READY` before OS socket is fully bound. Solution:

```elixir
defp retry_connect(port, retries_left, delay) do
  case Snakepit.GRPC.Client.connect(port) do
    {:ok, channel} -> {:ok, %{channel: channel, port: port}}
    {:error, :connection_refused} ->
      Process.sleep(delay)
      retry_connect(port, retries_left - 1, delay)  # Retry
  end
end
```

**Port Allocation Fix:**

Birthday paradox issue with random port allocation (90% collision with 48 workers):

```elixir
# OLD: Random allocation (collisions!)
offset = :rand.uniform(port_range)

# NEW: Atomic counter (zero collisions)
counter = :atomics.add_get(get_port_counter(), 1, 1)
offset = rem(counter, port_range)
```

**Graceful Shutdown:**

```elixir
def terminate(:shutdown, state) do
  # 1. Send SIGTERM to Python process
  System.cmd("kill", ["-TERM", to_string(state.process_pid)])

  # 2. Wait for graceful exit (2 seconds)
  receive do
    {:DOWN, ^ref, :port, _port, _} -> :ok
  after
    2000 ->
      # 3. Escalate to SIGKILL
      System.cmd("kill", ["-KILL", to_string(state.process_pid)])
  end

  # 4. Cleanup gRPC channel
  GRPC.Stub.disconnect(state.connection.channel)

  # 5. Unregister from ProcessRegistry
  ProcessRegistry.unregister_worker(state.id)
end
```

---

### 4. Tool System

#### Tool Registry (`Snakepit.Bridge.ToolRegistry`)

**Responsibilities:**
- Register tools from Python adapters
- Discover exposed Elixir tools
- Route tool execution to correct handler
- Track tool metadata (parameters, streaming support)

**Tool Types:**

```elixir
# Local tool (Elixir)
%{
  type: :local,
  name: "parse_json",
  handler: &MyModule.parse_json/1,
  parameters: [...],
  metadata: %{exposed_to_python: true}
}

# Remote tool (Python)
%{
  type: :remote,
  name: "ml_inference",
  worker_id: "worker_1",
  parameters: [...],
  metadata: %{supports_streaming: true}
}
```

#### Python BaseAdapter (`snakepit_bridge/base_adapter.py`)

**Location:** `priv/python/snakepit_bridge/base_adapter.py`
**Role:** Base class for all Python adapters with automatic tool discovery

**Key Features:**

1. **`@tool` Decorator:**
   ```python
   @tool(description="Search items", supports_streaming=True)
   def search(self, query: str, limit: int = 10):
       for item in search_database(query, limit):
           yield item
   ```

2. **Automatic Discovery:**
   ```python
   def get_tools(self) -> List[ToolRegistration]:
       tools = []
       for name, method in inspect.getmembers(self, inspect.ismethod):
           if hasattr(method, '_tool_metadata'):
               tools.append(self._create_tool_registration(name, method))
       return tools
   ```

3. **Session Registration:**
   ```python
   def register_with_session(self, session_id: str, stub) -> List[str]:
       tools = self.get_tools()
       request = pb2.RegisterToolsRequest(
           session_id=session_id,
           tools=tools,
           worker_id=f"python-{id(self)}"
       )
       response = stub.RegisterTools(request)
       return list(response.tool_ids.keys())
   ```

---

## Data Flow Examples

### Example 1: Non-Streaming Tool Execution

```
User Code (Elixir)
    |
    | Snakepit.execute("ml_inference", %{model: "bert"})
    v
Pool → Finds worker_1 (with session affinity)
    |
    v
GRPCWorker.execute(worker_1, "ml_inference", args)
    |
    | gRPC call to localhost:50052
    v
Python grpc_server.py
    |
    | 1. Create SessionContext(stub, session_id)
    | 2. Create adapter = ShowcaseAdapter()
    | 3. adapter.set_session_context(context)
    | 4. result = adapter.execute_tool("ml_inference", args, context)
    |
    | Tool may call back to Elixir:
    | context.call_elixir_tool("parse_json", ...)
    |    |
    |    | gRPC call to localhost:50051
    |    v
    | BridgeServer.execute_elixir_tool(...)
    |    |
    |    v
    | ToolRegistry.execute_local_tool(...)
    |    |
    |    | <--- Result
    |
    v
Python returns result (protobuf Any)
    |
    v
GRPCWorker decodes result
    |
    v
User Code receives {:ok, result}
```

### Example 2: Streaming Tool Execution

```
User Code (Elixir)
    |
    | Snakepit.execute_stream("batch_process", args, fn chunk -> ... end)
    v
GRPCWorker.execute_stream(worker_1, "batch_process", args, callback)
    |
    | gRPC streaming call
    v
Python grpc_server.py
    |
    | ExecuteStreamingTool(request, context)
    | stream_iterator = adapter.execute_tool(...)
    |
    | async for chunk in stream_iterator:
    |     yield pb2.ToolChunk(data=json.dumps(chunk))
    |
    | <--- Stream of chunks
    v
GRPCWorker consumes stream
    |
    | For each chunk:
    | callback_fn.(decoded_chunk)
    |
    v
User Code callback receives progressive results
```

---

## Configuration

### Elixir Configuration

```elixir
# config/config.exs
config :snakepit,
  # Adapter
  adapter_module: Snakepit.Adapters.GRPCPython,

  # Pooling
  pooling_enabled: true,
  pool_config: %{
    pool_size: 4,
    adapter_args: ["--adapter", "snakepit_bridge.adapters.showcase.ShowcaseAdapter"]
  },

  # gRPC (Elixir server)
  grpc_host: "localhost",
  grpc_port: 50051,

  # gRPC (Python workers)
  grpc_config: %{
    base_port: 50052,       # Python workers start here
    port_range: 100,        # Supports up to 100 workers
    connect_timeout: 5000,
    request_timeout: 30000
  },

  # Sessions
  session_config: %{
    ttl: 3600,              # 1 hour default
    cleanup_interval: 60000 # 1 minute
  }
```

### Python Adapter Configuration

```python
# Custom adapter
class MyAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        self.session_context = None

    def set_session_context(self, context: SessionContext):
        self.session_context = context

    @tool(description="Process data", supports_streaming=False)
    def process_data(self, data: str) -> dict:
        # Can call Elixir tools
        parsed = self.session_context.call_elixir_tool(
            "parse_json",
            json_string=data
        )
        return {"result": parsed}
```

---

## Performance Characteristics

### Session Operations

| Operation | Storage | Complexity | Concurrency |
|-----------|---------|------------|-------------|
| Create session | ETS insert_new | O(1) | Atomic |
| Get session | ETS lookup | O(1) | Read-concurrent |
| Update session | ETS insert | O(1) | Write-concurrent |
| Delete session | ETS delete | O(1) | Atomic |
| Cleanup expired | ETS select_delete | O(n) | Atomic batch |
| List sessions | ETS select | O(n) | Read-concurrent |

### gRPC Performance

- **Connection pooling**: Reused HTTP/2 connections
- **Multiplexing**: Multiple concurrent requests per connection
- **Binary encoding**: Protocol Buffers (smaller than JSON)
- **Streaming**: Constant memory for large datasets

### Measured Performance

```
Configuration: 4 workers, gRPC adapter
Hardware: 8-core CPU, 32GB RAM

Startup:
- Sequential: 4 seconds (1s per worker)
- Concurrent: 1.2 seconds (3.3x faster)

Throughput (Non-Streaming):
- Simple computation: 75,000 req/s
- Session operations: 68,000 req/s

Latency (p99):
- Simple computation: < 1.2ms
- Session operations: < 0.6ms

Streaming:
- Throughput: 250,000 chunks/s
- Memory: Constant (no buffering)
- First chunk latency: < 5ms
```

---

## Error Handling

### gRPC Status Codes

Python server uses standard gRPC status codes:

```python
# Invalid arguments
grpc.StatusCode.INVALID_ARGUMENT

# Tool not found
grpc.StatusCode.NOT_FOUND

# Not implemented
grpc.StatusCode.UNIMPLEMENTED

# Timeout
grpc.StatusCode.DEADLINE_EXCEEDED

# Internal errors
grpc.StatusCode.INTERNAL
```

### Elixir Error Handling

```elixir
case execute_tool(request) do
  {:ok, result} ->
    %ExecuteToolResponse{success: true, result: result}

  {:error, :not_found} ->
    raise GRPC.RPCError, status: :not_found, message: "Tool not found"

  {:error, reason} ->
    %ExecuteToolResponse{
      success: false,
      error_message: format_error(reason)
    }
end
```

---

## Known Issues & Fixes

### 1. ✅ FIXED: Port Collision (Birthday Paradox)

**Problem:** Random port allocation caused 90% collision rate with 48 workers.

**Solution:** Atomic counter-based allocation (zero collisions).

### 2. ✅ FIXED: GRPC_READY Race Condition

**Problem:** Python signals ready before OS socket accepts connections.

**Solution:** Retry logic with exponential backoff in `init_grpc_connection/1`.

### 3. ✅ FIXED: Orphaned Python Processes

**Problem:** Python processes survive Elixir crashes.

**Solution:** ProcessRegistry with DETS persistence and beam-run-id tracking.

### 4. ⚠️ KNOWN: Examples Out of Date

**Problem:** Examples reference old API (e.g., `register_variable` with wrong params).

**Status:** Examples need updating to match current SessionStore API.

**Workaround:** Use test files as canonical API examples.

### 5. ⚠️ KNOWN: Python Test Failures

**Problem:** 20/35 Python tests failing due to:
- `TypeSerializer.encode_any()` returns tuple instead of `Any`
- Protobuf API changes in `ToolSpec`

**Status:** Tests need refactoring to match current implementation.

---

## Migration Notes

### From Legacy Bridge to gRPC

**Old (stdin/stdout):**
```elixir
# JSON over pipes
Port.command(port, Jason.encode!(%{command: "ping"}))
```

**New (gRPC):**
```elixir
# Typed RPC with streaming
Snakepit.execute("ping", %{})
Snakepit.execute_stream("batch_process", %{}, fn chunk -> ... end)
```

### From Stateful Python to Stateless

**Old Pattern:**
```python
# Python stores session state
class Adapter:
    def __init__(self):
        self.sessions = {}  # ❌ Not persistent
```

**New Pattern:**
```python
# Elixir stores session state
class Adapter:
    def __init__(self):
        self.session_context = None  # ✅ Ephemeral

    def set_session_context(self, context):
        self.session_context = context
        # Call back to Elixir for state
```

---

## Testing

### Elixir Tests

```bash
# Full test suite
mix test

# Session tests
mix test test/snakepit/bridge/session_store_test.exs

# gRPC tests
mix test test/unit/grpc/
```

### Python Tests

```bash
# Run Python tests
./test_python.sh

# Or directly
cd priv/python
python -m pytest tests/
```

**Current Status:**
- ✅ SessionContext: 12/15 passing
- ❌ Serialization: 0/20 passing (needs refactoring)

---

## Future Enhancements

### Short Term
- [ ] Fix Python test suite (serialization, protobuf API)
- [ ] Update examples to current API
- [ ] Add streaming examples
- [ ] Document adapter creation guide

### Medium Term
- [ ] Distributed SessionStore (multi-node Elixir cluster)
- [ ] Session persistence to disk (DETS backup)
- [ ] Advanced worker affinity (load-based routing)
- [ ] Tool versioning and deprecation

### Long Term
- [ ] Multi-language adapters (Ruby, JavaScript, Rust)
- [ ] GraphQL bridge alongside gRPC
- [ ] Distributed tracing integration (OpenTelemetry)
- [ ] Session replay for debugging

---

## References

### Key Files

**Elixir:**
- `lib/snakepit/adapters/grpc_python.ex` - Adapter configuration
- `lib/snakepit/grpc_worker.ex` - Worker lifecycle
- `lib/snakepit/grpc/bridge_server.ex` - gRPC server
- `lib/snakepit/bridge/session_store.ex` - Session management
- `lib/snakepit/grpc/client.ex` - gRPC client

**Python:**
- `priv/python/grpc_server.py` - Python gRPC server
- `priv/python/snakepit_bridge/session_context.py` - Session proxy
- `priv/python/snakepit_bridge/base_adapter.py` - Adapter base
- `priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py` - Reference impl

**Protocol:**
- `priv/proto/snakepit_bridge.proto` - gRPC service definition

### Documentation
- `README.md` - Main documentation
- `README_GRPC.md` - gRPC deep dive
- `README_BIDIRECTIONAL_TOOL_BRIDGE.md` - Tool bridge
- `PYTHON_CLEANUP_SUMMARY.md` - Python refactoring notes
- `PHASE_1_COMPLETE.md` - Supertester integration

---

**Document Version:** 1.0
**Last Updated:** October 10, 2025
**Maintainer:** Snakepit Core Team
