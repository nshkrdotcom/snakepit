# Workers and Sessions

This document provides comprehensive documentation for Snakepit's worker profiles and session management systems. Workers are the fundamental execution units that run Python code, while sessions provide stateful affinity for routing requests to specific workers.

## Table of Contents

1. [Worker Profiles](#worker-profiles)
   - [Process Profile](#process-profile)
   - [Thread Profile](#thread-profile)
   - [Choosing a Profile](#choosing-a-profile)
2. [Worker Lifecycle](#worker-lifecycle)
   - [Spawning and Initialization](#spawning-and-initialization)
   - [Request Handling](#request-handling)
   - [Heartbeat Monitoring](#heartbeat-monitoring)
   - [Termination and Cleanup](#termination-and-cleanup)
3. [Session Management](#session-management)
   - [Session Creation and Storage](#session-creation-and-storage)
   - [Session Affinity](#session-affinity)
   - [Session State and Metadata](#session-state-and-metadata)
   - [TTL and Expiration](#ttl-and-expiration)
4. [Working Examples](#working-examples)
   - [Process Pool Configuration](#process-pool-configuration)
   - [Thread Pool Configuration](#thread-pool-configuration)
   - [Session-Based Execution](#session-based-execution)

---

## Worker Profiles

Snakepit supports two worker profiles that define how Python processes are created and managed. The profile choice significantly impacts concurrency, isolation, and performance characteristics.

### Process Profile

**Module:** `Snakepit.WorkerProfile.Process`

The process profile is the default and most compatible mode. Each worker runs as a separate OS process with a single-threaded Python interpreter.

#### Description

- **Isolation Model:** Full process isolation. Each worker is an independent OS process with its own memory space. A crash in one worker cannot affect others.
- **GIL Handling:** The Global Interpreter Lock (GIL) is irrelevant since each process has its own interpreter.
- **Capacity:** Each worker handles exactly one request at a time (capacity = 1).

#### Use Cases

- **I/O-bound workloads:** Web scraping, API calls, file operations
- **High concurrency requirements:** 100+ simultaneous workers
- **Legacy Python code:** Works with all Python versions (3.8+)
- **Untrusted code execution:** Process isolation provides security boundaries
- **Memory-sensitive workloads:** Each worker's memory is isolated and can be recycled independently

#### Configuration

```elixir
config :snakepit,
  pools: [
    %{
      name: :default,
      worker_profile: :process,  # Explicit (or omit for default)
      pool_size: 100,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "1"},
        {"OMP_NUM_THREADS", "1"}
      ]
    }
  ]
```

#### Environment Variables

The process profile automatically enforces single-threading in scientific libraries:

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENBLAS_NUM_THREADS` | `"1"` | OpenBLAS thread control |
| `MKL_NUM_THREADS` | `"1"` | Intel MKL thread control |
| `OMP_NUM_THREADS` | `"1"` | OpenMP thread control |
| `NUMEXPR_NUM_THREADS` | `"1"` | NumExpr thread control |
| `VECLIB_MAXIMUM_THREADS` | `"1"` | macOS Accelerate framework |
| `GRPC_POLL_STRATEGY` | `"poll"` | gRPC polling strategy |

### Thread Profile

**Module:** `Snakepit.WorkerProfile.Thread`

The thread profile runs fewer Python processes, each with an internal thread pool. Optimized for Python 3.13+ with free-threading support.

#### Description

- **Isolation Model:** Thread-level isolation within processes. Multiple requests execute concurrently in the same Python interpreter via a `ThreadPoolExecutor`.
- **GIL Handling:** Requires Python 3.13+ for optimal performance. The free-threading mode eliminates GIL contention for CPU-bound tasks.
- **Capacity:** Each worker handles multiple concurrent requests (configurable via `threads_per_worker`).

#### Use Cases

- **CPU-bound workloads:** Machine learning inference, numerical computation
- **Large shared data:** Zero-copy data sharing within a worker process
- **Memory efficiency:** Fewer interpreter instances reduce memory footprint
- **High throughput:** HTTP/2 multiplexing enables concurrent requests to the same worker

#### Configuration

```elixir
config :snakepit,
  pools: [
    %{
      name: :hpc_pool,
      worker_profile: :thread,
      pool_size: 4,                    # 4 processes
      threads_per_worker: 16,          # 16 threads each = 64 total capacity
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_spec: "myapp.adapters.MLAdapter",
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "16"},
        {"OMP_NUM_THREADS", "16"}
      ],
      worker_ttl: {3600, :seconds},    # Recycle hourly
      worker_max_requests: 1000,       # Or after 1000 requests
      thread_safety_checks: true       # Enable runtime validation
    }
  ]
```

#### Requirements

- Python 3.13+ for optimal free-threading performance
- Thread-safe Python adapters
- Thread-safe ML libraries (NumPy, PyTorch, TensorFlow)

#### Capacity Tracking

The thread profile uses `Snakepit.WorkerProfile.Thread.CapacityStore` to track in-flight requests per worker. This enables:

- Load-aware worker selection
- Capacity limit enforcement
- Telemetry for monitoring load distribution

### Choosing a Profile

| Consideration | Process Profile | Thread Profile |
|---------------|-----------------|----------------|
| **Python Version** | 3.8+ | 3.13+ (optimal) |
| **Workload Type** | I/O-bound | CPU-bound |
| **Concurrency** | High (100+ workers) | Moderate (4-16 workers x N threads) |
| **Memory Usage** | Higher (many interpreters) | Lower (few interpreters) |
| **Isolation** | Full process isolation | Thread isolation only |
| **Crash Impact** | Single worker | Single worker (all threads) |
| **Data Sharing** | Via serialization | In-process (zero-copy) |
| **Configuration** | Simple | Requires thread-safe code |

**Decision Matrix:**

1. Use **Process Profile** if:
   - Running Python < 3.13
   - Code is not thread-safe
   - Need maximum isolation
   - I/O-bound workloads dominate

2. Use **Thread Profile** if:
   - Running Python 3.13+ with free-threading
   - Code is verified thread-safe
   - CPU-bound ML inference workloads
   - Memory efficiency is critical

---

## Worker Lifecycle

### Spawning and Initialization

Workers are spawned by the pool supervisor and go through a multi-stage initialization process.

#### 1. Process Creation

```
Pool.start_pool/1
    -> WorkerSupervisor.start_worker/5
        -> GRPCWorker.start_link/1
            -> GenServer.init/1
```

The `GRPCWorker.init/1` callback:

1. **Trap exits** - Ensures `terminate/2` is called for cleanup
2. **Reserve worker slot** - Registers with `ProcessRegistry`
3. **Generate session ID** - Creates a unique session identifier
4. **Build spawn configuration** - Assembles Python executable, args, and environment
5. **Spawn Python process** - Opens an Erlang port to the Python gRPC server
6. **Return `{:ok, state, {:continue, :connect_and_wait}}`**

#### 2. Connection Establishment

The `handle_continue(:connect_and_wait, state)` callback:

1. **Wait for server readiness** - Polls a ready file written by Python
2. **Establish gRPC connection** - Calls `adapter.init_grpc_connection/1`
3. **Notify pool** - Calls `GenServer.call(pool_pid, {:worker_ready, worker_id})`
4. **Initialize session** - Optionally calls `Client.initialize_session/3`
5. **Start heartbeat monitor** - Spawns linked `HeartbeatMonitor` process
6. **Emit telemetry** - `[:snakepit, :pool, :worker, :spawned]`

#### State Structure

```elixir
%{
  id: "worker_abc123",
  pool_name: :default,
  adapter: Snakepit.Adapters.GRPCPython,
  port: 50001,
  server_port: #Port<0.5>,
  process_pid: 12345,          # OS PID of Python process
  pgid: 12345,                 # Process group ID (if enabled)
  process_group?: true,
  session_id: "session_...",
  connection: %{channel: %GRPC.Channel{}},
  heartbeat_monitor: #PID<0.123.0>,
  heartbeat_config: %{...},
  health_check_ref: #Reference<...>,
  ready_file: "/tmp/snakepit_ready_...",
  stats: %{requests: 0, errors: 0, start_time: ...},
  worker_config: %{...}
}
```

### Request Handling

#### Standard Execution

```elixir
GRPCWorker.execute(worker, command, args, timeout)
```

Flow:
1. Resolve worker PID from worker ID if needed
2. `GenServer.call(pid, {:execute, command, args, timeout})`
3. Add correlation ID to args
4. Instrument with telemetry span
5. Call `adapter.grpc_execute(connection, session_id, command, args, timeout)`
6. Update stats (requests/errors)
7. Return `{:ok, result}` or `{:error, reason}`

#### Streaming Execution

```elixir
GRPCWorker.execute_stream(worker, command, args, callback_fn, timeout)
```

Streaming allows processing results incrementally via the callback function.

#### Session-Scoped Execution

```elixir
GRPCWorker.execute_in_session(worker, session_id, command, args, timeout)
```

Adds the session ID to the args for session-aware Python handlers.

### Heartbeat Monitoring

The heartbeat system detects unresponsive workers and triggers restarts.

#### Configuration

```elixir
heartbeat_config = %{
  enabled: true,
  ping_interval_ms: 2_000,      # How often to ping
  timeout_ms: 10_000,           # Max time to wait for pong
  max_missed_heartbeats: 3,     # Failures before declaring dead
  initial_delay_ms: 0,          # Delay before first ping
  dependent: true               # Worker dies if monitor dies
}
```

#### Heartbeat Flow

1. `HeartbeatMonitor` sends ping via `ping_fun`
2. `ping_fun` calls `adapter.grpc_heartbeat/2` or `Client.heartbeat/3`
3. On success: `HeartbeatMonitor.notify_pong/2` resets counters
4. On failure: Increment missed heartbeat counter
5. If `missed >= max_missed_heartbeats`: Exit monitor process
6. Worker receives `{:EXIT, monitor_pid, reason}` and terminates

### Termination and Cleanup

When a worker terminates (normal shutdown, crash, or heartbeat failure):

#### 1. Emit Telemetry

```elixir
:telemetry.execute(
  [:snakepit, :pool, :worker, :terminated],
  %{lifetime: ..., total_commands: ...},
  %{pool_name: ..., worker_id: ..., reason: ..., planned: true/false}
)
```

#### 2. Stop Heartbeat Monitor

```elixir
GenServer.stop(heartbeat_monitor, :shutdown)
```

#### 3. Kill Python Process

**Graceful shutdown** (`:shutdown`, `:normal`):
- Send `SIGTERM` to process/process group
- Wait up to 2000ms for graceful exit
- Escalate to `SIGKILL` if needed

**Non-graceful termination**:
- Immediately send `SIGKILL`

#### 4. Cleanup Resources

- Disconnect gRPC channel
- Cancel health check timer
- Close Erlang port
- Unregister from `GrpcStream`
- Unregister from `ProcessRegistry`
- Delete ready file

---

## Session Management

Sessions provide stateful context for routing requests to specific workers and storing program metadata.

### Session Creation and Storage

**Module:** `Snakepit.Bridge.SessionStore`

The `SessionStore` is a GenServer backed by ETS for high-performance concurrent access.

#### Creating a Session

```elixir
{:ok, session} = SessionStore.create_session("session_123")
{:ok, session} = SessionStore.create_session("session_456", ttl: 7200)
```

#### Session Struct

```elixir
%Snakepit.Bridge.Session{
  id: "session_123",
  programs: %{},                    # Stored program data
  metadata: %{},                    # Arbitrary metadata
  created_at: -576460751,           # Monotonic time (seconds)
  last_accessed: -576460751,        # Updated on each access
  last_worker_id: "worker_abc",     # For session affinity
  ttl: 3600,                        # Time-to-live in seconds
  stats: %{program_count: 0}
}
```

#### ETS Table Configuration

```elixir
:ets.new(:snakepit_sessions, [
  :set,
  :protected,
  :named_table,
  {:read_concurrency, true},
  {:write_concurrency, true},
  {:decentralized_counters, true}
])
```

The table stores records as:
```elixir
{session_id, {last_accessed, ttl, session_struct}}
```

This format enables efficient TTL-based expiration queries.

### Session Affinity

Session affinity routes requests with the same session ID to the same worker when possible.

#### Storing Affinity

```elixir
SessionStore.store_worker_session(session_id, worker_id)
```

This:
1. Looks up existing session or creates new one
2. Sets `last_worker_id` to the specified worker
3. Updates `last_accessed` timestamp

#### Using Affinity

When executing with a session:
1. Look up session in `SessionStore`
2. If `last_worker_id` is set and worker is available, route to that worker
3. Otherwise, select any available worker and update affinity

#### Benefits

- **Stateful Python:** Worker can maintain in-memory state between requests
- **Cache locality:** Worker may have cached data for this session
- **Resource reuse:** Avoid re-initializing per-session resources

### Session State and Metadata

#### Programs

Sessions can store program data (compiled code, intermediate results):

```elixir
# Store a program
session = Session.put_program(session, "program_1", %{code: "...", compiled: true})

# Retrieve a program
{:ok, program_data} = Session.get_program(session, "program_1")

# Delete a program
session = Session.delete_program(session, "program_1")
```

#### Metadata

Arbitrary key-value metadata:

```elixir
# Store metadata
session = Session.put_metadata(session, :user_id, "user_123")

# Retrieve metadata
user_id = Session.get_metadata(session, :user_id)
```

#### Statistics

```elixir
stats = Session.get_stats(session)
# %{
#   age: 120,                    # Seconds since creation
#   time_since_access: 5,        # Seconds since last access
#   total_items: 3,              # Number of programs
#   program_count: 3
# }
```

### TTL and Expiration

#### Default Configuration

```elixir
@default_ttl 3600          # 1 hour
@cleanup_interval 60_000   # 1 minute
@default_max_sessions 10_000
```

#### Automatic Cleanup

The `SessionStore` runs periodic cleanup:

```elixir
def handle_info(:cleanup_expired_sessions, state) do
  {_expired_count, new_stats} = do_cleanup_expired_sessions(state.table, state.stats)
  Process.send_after(self(), :cleanup_expired_sessions, state.cleanup_interval)
  {:noreply, %{state | stats: new_stats}}
end
```

The cleanup uses an efficient `select_delete` match spec:

```elixir
match_spec = [
  {{:_, {:"$1", :"$2", :_}},
   [{:<, {:+, :"$1", :"$2"}, current_time}],
   [true]}
]
expired_count = :ets.select_delete(table, match_spec)
```

#### Touch Behavior

Each `get_session/1` call automatically updates `last_accessed`:

```elixir
def get_session(session_id) do
  case :ets.lookup(state.table, session_id) do
    [{^session_id, {_last_accessed, _ttl, session}}] ->
      touched_session = Session.touch(session)  # Updates last_accessed
      :ets.insert(state.table, updated_record)
      {:ok, touched_session}
    [] ->
      {:error, :not_found}
  end
end
```

#### Manual Cleanup

```elixir
expired_count = SessionStore.cleanup_expired_sessions()
```

#### Session Quota

The store enforces a maximum session count:

```elixir
defp check_session_quota(state) do
  if :ets.info(state.table, :size) >= state.max_sessions do
    {:error, :session_quota_exceeded}
  else
    :ok
  end
end
```

---

## Working Examples

### Process Pool Configuration

Standard multi-process pool for I/O-bound workloads:

```elixir
# config/config.exs
config :snakepit,
  pools: [
    %{
      name: :web_scrapers,
      worker_profile: :process,
      pool_size: 50,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "1"},
        {"OMP_NUM_THREADS", "1"}
      ],
      heartbeat: %{
        enabled: true,
        ping_interval_ms: 5_000,
        timeout_ms: 15_000,
        max_missed_heartbeats: 3
      }
    }
  ]

# Usage
{:ok, result} = Snakepit.execute(:web_scrapers, "scrape_url", %{url: "https://example.com"})
```

### Thread Pool Configuration

Multi-threaded pool for ML inference:

```elixir
# config/config.exs
config :snakepit,
  pools: [
    %{
      name: :ml_inference,
      worker_profile: :thread,
      pool_size: 4,                      # 4 Python processes
      threads_per_worker: 8,             # 8 threads each = 32 total capacity
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_spec: "myapp.ml.InferenceAdapter",
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "8"},
        {"OMP_NUM_THREADS", "8"},
        {"CUDA_VISIBLE_DEVICES", "0"}
      ],
      thread_safety_checks: true,
      worker_ttl: {1800, :seconds},      # Recycle every 30 minutes
      heartbeat: %{
        enabled: true,
        ping_interval_ms: 10_000,
        timeout_ms: 30_000,
        max_missed_heartbeats: 2
      }
    }
  ]

# Usage
{:ok, predictions} = Snakepit.execute(:ml_inference, "predict", %{
  model: "resnet50",
  images: ["img1.jpg", "img2.jpg", "img3.jpg"]
})
```

### Session-Based Execution

Maintaining state across requests with session affinity:

```elixir
# Start the SessionStore (usually in application supervision tree)
{:ok, _pid} = Snakepit.Bridge.SessionStore.start_link()

# Create a session for a user
session_id = "user_#{user_id}_session"
{:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 7200)

# First request - initializes state in Python
{:ok, worker_pid} = Snakepit.Pool.checkout(:ml_inference)
{:ok, _result} = Snakepit.GRPCWorker.execute_in_session(
  worker_pid,
  session_id,
  "initialize_model",
  %{model_name: "custom_model", weights: "path/to/weights"}
)

# Store affinity for future requests
{:ok, worker_id} = Snakepit.Pool.Registry.get_worker_id_by_pid(worker_pid)
Snakepit.Bridge.SessionStore.store_worker_session(session_id, worker_id)
Snakepit.Pool.checkin(:ml_inference, worker_pid)

# Subsequent requests - routed to same worker
{:ok, session} = Snakepit.Bridge.SessionStore.get_session(session_id)
preferred_worker_id = session.last_worker_id

# Checkout with preference
{:ok, worker_pid} = case Snakepit.Pool.Registry.get_worker_pid(preferred_worker_id) do
  {:ok, pid} -> {:ok, pid}
  {:error, _} -> Snakepit.Pool.checkout(:ml_inference)
end

# Execute - Python can access previously initialized state
{:ok, predictions} = Snakepit.GRPCWorker.execute_in_session(
  worker_pid,
  session_id,
  "predict",
  %{input_data: data}
)

# Cleanup when done
Snakepit.Bridge.SessionStore.delete_session(session_id)
```

#### Session with Metadata

```elixir
# Create session with initial metadata
{:ok, session} = Snakepit.Bridge.SessionStore.create_session(
  "analysis_session",
  ttl: 3600,
  metadata: %{user_id: "user_123", project: "experiment_1"}
)

# Update session with results
{:ok, updated_session} = Snakepit.Bridge.SessionStore.update_session(
  "analysis_session",
  fn session ->
    session
    |> Snakepit.Bridge.Session.put_metadata(:last_analysis, DateTime.utc_now())
    |> Snakepit.Bridge.Session.put_program("analysis_v1", %{
      status: :completed,
      result_path: "/results/exp1.json"
    })
  end
)

# Check session statistics
stats = Snakepit.Bridge.SessionStore.get_stats()
# %{
#   current_sessions: 1,
#   memory_usage_bytes: 4096,
#   sessions_created: 1,
#   sessions_deleted: 0,
#   sessions_expired: 0,
#   cleanup_runs: 5,
#   ...
# }
```

---

## Related Documentation

- [Pool Management](01-pool-management.md) - Pool configuration and worker supervision
- [Adapters](03-adapters.md) - Python adapter implementation
- [Telemetry](../telemetry_events.md) - Monitoring and observability
