# Snakepit Telemetry Event Catalog

**Date:** 2025-10-28
**Status:** Design Document

This document catalogs all telemetry events emitted by Snakepit.

---

## Event Format

All events follow this structure:

```elixir
:telemetry.execute(
  event_name :: [atom()],           # [:snakepit, :component, :resource, :action]
  measurements :: %{atom() => number()},
  metadata :: %{atom() => term()}
)
```

---

## Layer 1: Infrastructure Events

### Pool Management

#### `[:snakepit, :pool, :initialized]`

Emitted when a pool completes initialization.

**Measurements:**
```elixir
%{
  duration: integer(),              # Time to initialize (native time)
  system_time: integer()            # System.system_time()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  size: integer(),                  # Configured pool size
  adapter_module: module(),
  worker_module: module()
}
```

#### `[:snakepit, :pool, :status]`

Periodic snapshot of pool status (emitted by telemetry poller).

**Measurements:**
```elixir
%{
  available_workers: integer(),
  busy_workers: integer(),
  queue_depth: integer(),
  total_workers: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom()
}
```

#### `[:snakepit, :pool, :queue, :enqueued]`

Request added to pool queue (no workers available).

**Measurements:**
```elixir
%{
  queue_depth: integer(),
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  command: String.t(),
  session_id: String.t() | nil,
  correlation_id: String.t()
}
```

#### `[:snakepit, :pool, :queue, :dequeued]`

Request removed from queue (worker became available).

**Measurements:**
```elixir
%{
  queue_time: integer(),            # Time spent in queue (native time)
  queue_depth: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  correlation_id: String.t()
}
```

#### `[:snakepit, :pool, :queue, :timeout]`

Request timed out while queued.

**Measurements:**
```elixir
%{
  queue_time: integer(),
  queue_depth: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  timeout_ms: integer(),
  correlation_id: String.t()
}
```

---

### Worker Lifecycle

#### `[:snakepit, :pool, :worker, :spawn_started]`

Worker spawn initiated.

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  worker_module: module()
}
```

#### `[:snakepit, :pool, :worker, :spawned]`

Worker successfully started and ready.

**Measurements:**
```elixir
%{
  duration: integer(),              # Spawn time (native time)
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  worker_pid: pid(),
  python_port: integer() | nil,     # gRPC port if applicable
  mode: :process | :thread
}
```

#### `[:snakepit, :pool, :worker, :spawn_failed]`

Worker failed to start.

**Measurements:**
```elixir
%{
  duration: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  reason: term(),
  retry_count: integer()
}
```

#### `[:snakepit, :pool, :worker, :terminated]`

Worker process terminated.

**Measurements:**
```elixir
%{
  lifetime: integer(),              # Total worker lifetime (native time)
  total_commands: integer()         # Commands executed during lifetime
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  worker_pid: pid(),
  reason: term(),                   # :normal, :shutdown, {:error, reason}
  planned: boolean()                # true if graceful shutdown
}
```

#### `[:snakepit, :pool, :worker, :restarted]`

Worker restarted by supervisor.

**Measurements:**
```elixir
%{
  downtime: integer(),              # Time between death and restart (native time)
  restart_count: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  previous_pid: pid(),
  new_pid: pid(),
  reason: term()
}
```

---

### Session Management

#### `[:snakepit, :session, :created]`

New session created.

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  session_id: String.t(),
  pool_name: atom()
}
```

#### `[:snakepit, :session, :destroyed]`

Session destroyed.

**Measurements:**
```elixir
%{
  lifetime: integer(),              # Session lifetime (native time)
  command_count: integer()          # Commands executed in session
}
```

**Metadata:**
```elixir
%{
  node: node(),
  session_id: String.t(),
  pool_name: atom(),
  reason: :explicit | :timeout | :worker_died
}
```

#### `[:snakepit, :session, :affinity, :assigned]`

Session assigned to specific worker (affinity created).

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  session_id: String.t(),
  worker_id: String.t(),
  pool_name: atom()
}
```

#### `[:snakepit, :session, :affinity, :broken]`

Session affinity broken (worker died, manual override).

**Measurements:**
```elixir
%{
  affinity_duration: integer(),     # How long affinity lasted
  commands_with_affinity: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  session_id: String.t(),
  worker_id: String.t(),
  reason: :worker_died | :reassigned
}
```

---

## Layer 2: Python Execution Events (Folded from Python)

### Command Execution

#### `[:snakepit, :python, :call, :start]`

Python command execution started.

**Measurements:**
```elixir
%{
  system_time: integer(),
  request_size: integer() | nil     # Bytes if measurable
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  session_id: String.t() | nil,
  command: String.t(),
  correlation_id: String.t()
}
```

#### `[:snakepit, :python, :call, :stop]`

Python command execution completed successfully.

**Measurements:**
```elixir
%{
  duration: integer(),              # Execution time (native time)
  response_size: integer() | nil    # Bytes if measurable
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  session_id: String.t() | nil,
  command: String.t(),
  correlation_id: String.t(),
  result: :success
}
```

#### `[:snakepit, :python, :call, :exception]`

Python command raised an exception.

**Measurements:**
```elixir
%{
  duration: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  session_id: String.t() | nil,
  command: String.t(),
  correlation_id: String.t(),
  error_type: String.t(),           # Python exception class name
  error_category: :timeout | :python_error | :worker_error
}
```

---

### Python Resource Metrics

#### `[:snakepit, :python, :memory, :sampled]`

Python process memory usage sampled.

**Measurements:**
```elixir
%{
  rss_bytes: integer(),             # Resident set size
  vms_bytes: integer(),             # Virtual memory size
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  python_pid: integer()
}
```

#### `[:snakepit, :python, :cpu, :sampled]`

Python process CPU usage sampled.

**Measurements:**
```elixir
%{
  cpu_percent: float(),             # CPU utilization percentage
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  python_pid: integer()
}
```

#### `[:snakepit, :python, :gc, :completed]`

Python garbage collection completed (if Python reports it).

**Measurements:**
```elixir
%{
  duration: integer(),              # GC duration (microseconds)
  collected: integer(),             # Objects collected
  generation: integer()             # GC generation (0, 1, 2)
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t()
}
```

---

### Python Errors

#### `[:snakepit, :python, :error, :occurred]`

Python-side error detected (not necessarily a call exception).

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  pool_name: atom(),
  worker_id: String.t(),
  error_type: String.t(),
  error_message: String.t(),
  traceback: String.t() | nil
}
```

---

## Layer 3: gRPC Bridge Events

### gRPC Communication

#### `[:snakepit, :grpc, :call, :start]`

gRPC call initiated to Python worker.

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  rpc_method: String.t(),           # execute_tool, execute_streaming_tool, etc.
  correlation_id: String.t()
}
```

#### `[:snakepit, :grpc, :call, :stop]`

gRPC call completed.

**Measurements:**
```elixir
%{
  duration: integer(),
  network_time: integer() | nil     # Time on wire, if measurable
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  rpc_method: String.t(),
  correlation_id: String.t(),
  grpc_status: atom()               # :ok, :unavailable, etc.
}
```

#### `[:snakepit, :grpc, :call, :exception]`

gRPC call failed.

**Measurements:**
```elixir
%{
  duration: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  rpc_method: String.t(),
  correlation_id: String.t(),
  grpc_status: atom(),
  error_message: String.t()
}
```

---

### gRPC Streaming

#### `[:snakepit, :grpc, :stream, :opened]`

Streaming RPC opened.

**Measurements:**
```elixir
%{
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  stream_id: String.t(),
  correlation_id: String.t()
}
```

#### `[:snakepit, :grpc, :stream, :message]`

Message sent or received on stream.

**Measurements:**
```elixir
%{
  message_size: integer(),          # Bytes
  sequence_number: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  stream_id: String.t(),
  direction: :request | :response,
  is_final: boolean()
}
```

#### `[:snakepit, :grpc, :stream, :closed]`

Stream closed.

**Measurements:**
```elixir
%{
  duration: integer(),              # Total stream lifetime
  message_count: integer()          # Total messages sent/received
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  stream_id: String.t(),
  reason: :completed | :error | :cancelled
}
```

---

### gRPC Connection Health

#### `[:snakepit, :grpc, :connection, :established]`

gRPC channel connected to Python worker.

**Measurements:**
```elixir
%{
  duration: integer(),              # Connection establishment time
  system_time: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  python_port: integer(),
  retry_count: integer()
}
```

#### `[:snakepit, :grpc, :connection, :lost]`

gRPC channel lost connection.

**Measurements:**
```elixir
%{
  uptime: integer(),                # How long connection was alive
  call_count: integer()             # Calls made during connection
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t(),
  reason: atom()
}
```

#### `[:snakepit, :grpc, :connection, :reconnected]`

gRPC channel reconnected after failure.

**Measurements:**
```elixir
%{
  downtime: integer(),              # Time between lost and reconnected
  retry_count: integer()
}
```

**Metadata:**
```elixir
%{
  node: node(),
  worker_id: String.t()
}
```

---

## Correlation IDs

All events related to a single request should include the same `correlation_id`:

```elixir
# Generate at request entry point
correlation_id = UUID.uuid4()

# Flows through all events
[:snakepit, :pool, :queue, :enqueued]       # correlation_id: "abc-123"
[:snakepit, :python, :call, :start]         # correlation_id: "abc-123"
[:snakepit, :grpc, :call, :start]           # correlation_id: "abc-123"
[:snakepit, :python, :call, :stop]          # correlation_id: "abc-123"
[:snakepit, :pool, :queue, :dequeued]       # correlation_id: "abc-123"
```

This enables distributed tracing across:
- Elixir → Pool → Worker → gRPC → Python
- Multiple nodes in cluster
- Request → Response lifecycle

---

## Event Frequency & Sampling

### High Frequency (Consider Sampling)
- `[:snakepit, :python, :call, :*]` - Every command execution
- `[:snakepit, :grpc, :call, :*]` - Every gRPC call
- `[:snakepit, :grpc, :stream, :message]` - Every stream message

**Recommendation:** Sample 10-25% unless debugging

### Medium Frequency
- `[:snakepit, :pool, :queue, :*]` - When queue active
- `[:snakepit, :pool, :worker, :*]` - Worker lifecycle
- `[:snakepit, :session, :*]` - Session lifecycle

**Recommendation:** Always emit

### Low Frequency
- `[:snakepit, :pool, :status]` - Periodic (every 5-60s)
- `[:snakepit, :python, :memory, :sampled]` - Periodic (every 10-60s)
- `[:snakepit, :grpc, :connection, :*]` - Connection changes

**Recommendation:** Always emit

---

## Usage Examples

### Track Average Command Duration

```elixir
:telemetry.attach(
  "track-duration",
  [:snakepit, :python, :call, :stop],
  fn _event, %{duration: duration}, _metadata, _config ->
    # duration in native time units
    duration_ms = duration / 1_000_000
    MyApp.Metrics.record_duration(duration_ms)
  end,
  nil
)
```

### Monitor Queue Depth

```elixir
:telemetry.attach(
  "queue-alert",
  [:snakepit, :pool, :status],
  fn _event, %{queue_depth: depth}, %{pool_name: pool}, _config ->
    if depth > 50 do
      Logger.warning("High queue depth: #{depth} for pool #{pool}")
    end
  end,
  nil
)
```

### Track Worker Restarts

```elixir
:telemetry.attach(
  "restart-counter",
  [:snakepit, :pool, :worker, :restarted],
  fn _event, %{restart_count: count}, metadata, _config ->
    if count > 5 do
      Logger.error("Worker restarting frequently",
        worker_id: metadata.worker_id,
        restart_count: count
      )
    end
  end,
  nil
)
```

### Distributed Tracing

```elixir
:telemetry.attach_many(
  "trace-request",
  [
    [:snakepit, :pool, :queue, :enqueued],
    [:snakepit, :python, :call, :start],
    [:snakepit, :python, :call, :stop]
  ],
  fn event, measurements, %{correlation_id: id} = metadata, _config ->
    OpenTelemetry.Span.add_event(id, event, measurements, metadata)
  end,
  nil
)
```

---

**Next:** [02_PYTHON_INTEGRATION.md](./02_PYTHON_INTEGRATION.md) - Python telemetry emitter
