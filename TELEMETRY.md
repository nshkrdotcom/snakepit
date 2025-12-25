# Snakepit Telemetry

> Updated for Snakepit v0.7.2

Snakepit provides a comprehensive distributed telemetry system that enables observability across your Elixir cluster and Python workers. All telemetry flows through Elixir's standard `:telemetry` library, providing a unified interface for monitoring, metrics, and tracing.

## Features

- **Distributed by Design** - All events include node metadata for cluster-wide visibility
- **Python-to-Elixir Event Folding** - Python worker metrics appear as Elixir `:telemetry` events
- **Bidirectional gRPC Stream** - Real-time event streaming with runtime control
- **Atom Safety** - Curated event catalog prevents atom table exhaustion
- **Runtime Control** - Adjust sampling rates, filtering, and toggle telemetry without restarting workers
- **Zero External Dependencies** - Core system uses only stdlib + `:telemetry`
- **High Performance** - <10μs overhead per event, <1% CPU impact

## Quick Start

### Attaching Event Handlers

```elixir
# In your application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Attach telemetry handlers
    :telemetry.attach(
      "my-app-python-monitor",
      [:snakepit, :python, :call, :stop],
      &MyApp.Telemetry.handle_python_call/4,
      nil
    )

    children = [
      # ... your supervision tree
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule MyApp.Telemetry do
  require Logger

  def handle_python_call(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration / 1_000_000

    Logger.info("Python call completed",
      command: metadata.command,
      duration_ms: duration_ms,
      worker_id: metadata.worker_id,
      node: metadata.node
    )
  end
end
```

### Emitting from Python

```python
from snakepit_bridge import telemetry

def my_tool(ctx, data):
    # Use span for automatic timing
    with telemetry.span("tool.execution", {"tool": "my_tool"}):
        result = expensive_operation(data)

        # Emit custom metrics
        telemetry.emit(
            "tool.result_size",
            {"bytes": len(result)},
            {"tool": "my_tool"}
        )

        return result
```

## Event Catalog

Snakepit emits events across three layers:

### Layer 1: Infrastructure Events (Elixir)

**Pool Management:**
- `[:snakepit, :pool, :initialized]` - Pool initialization complete
- `[:snakepit, :pool, :status]` - Periodic pool status snapshot
- `[:snakepit, :pool, :queue, :enqueued]` - Request queued (no workers available)
- `[:snakepit, :pool, :queue, :dequeued]` - Request dequeued (worker available)
- `[:snakepit, :pool, :queue, :timeout]` - Request timed out in queue

**Worker Lifecycle:**
- `[:snakepit, :pool, :worker, :spawn_started]` - Worker spawn initiated
- `[:snakepit, :pool, :worker, :spawned]` - Worker ready and connected
- `[:snakepit, :pool, :worker, :spawn_failed]` - Worker failed to start
- `[:snakepit, :pool, :worker, :terminated]` - Worker terminated
- `[:snakepit, :pool, :worker, :restarted]` - Worker restarted by supervisor

**Session Management:**
- `[:snakepit, :session, :created]` - New session created
- `[:snakepit, :session, :destroyed]` - Session destroyed
- `[:snakepit, :session, :affinity, :assigned]` - Session assigned to worker
- `[:snakepit, :session, :affinity, :broken]` - Session affinity broken

### Layer 2: Python Execution Events (Folded from Python)

**Call Lifecycle:**
- `[:snakepit, :python, :call, :start]` - Python command started
- `[:snakepit, :python, :call, :stop]` - Python command completed successfully
- `[:snakepit, :python, :call, :exception]` - Python command raised exception

**Tool Execution:**
- `[:snakepit, :python, :tool, :execution, :start]` - Tool execution started
- `[:snakepit, :python, :tool, :execution, :stop]` - Tool execution completed
- `[:snakepit, :python, :tool, :execution, :exception]` - Tool execution failed
- `[:snakepit, :python, :tool, :result_size]` - Tool result size metric

**Resource Metrics:**
- `[:snakepit, :python, :memory, :sampled]` - Python process memory usage
- `[:snakepit, :python, :cpu, :sampled]` - Python process CPU usage
- `[:snakepit, :python, :gc, :completed]` - Python garbage collection completed
- `[:snakepit, :python, :error, :occurred]` - Python error detected

### Layer 3: gRPC Bridge Events (Elixir)

**Call Events:**
- `[:snakepit, :grpc, :call, :start]` - gRPC call initiated
- `[:snakepit, :grpc, :call, :stop]` - gRPC call completed
- `[:snakepit, :grpc, :call, :exception]` - gRPC call failed

**Stream Events:**
- `[:snakepit, :grpc, :stream, :opened]` - Streaming RPC opened
- `[:snakepit, :grpc, :stream, :message]` - Stream message sent/received
- `[:snakepit, :grpc, :stream, :closed]` - Stream closed

**Connection Events:**
- `[:snakepit, :grpc, :connection, :established]` - gRPC channel connected
- `[:snakepit, :grpc, :connection, :lost]` - gRPC connection lost
- `[:snakepit, :grpc, :connection, :reconnected]` - gRPC reconnected after failure

## Usage Patterns

### Monitoring Python Call Performance

```elixir
:telemetry.attach(
  "python-perf-monitor",
  [:snakepit, :python, :call, :stop],
  fn _event, %{duration: duration}, metadata, _ ->
    duration_ms = duration / 1_000_000

    if duration_ms > 1000 do
      Logger.warning("Slow Python call detected",
        command: metadata.command,
        duration_ms: duration_ms,
        worker_id: metadata.worker_id
      )
    end
  end,
  nil
)
```

### Tracking Worker Health

```elixir
:telemetry.attach(
  "worker-health-monitor",
  [:snakepit, :pool, :worker, :restarted],
  fn _event, %{restart_count: count}, metadata, _ ->
    if count > 5 do
      Logger.error("Worker restarting frequently",
        worker_id: metadata.worker_id,
        restart_count: count,
        reason: metadata.reason
      )

      # Alert ops team
      MyApp.Alerts.send_alert(:worker_flapping, metadata)
    end
  end,
  nil
)
```

### Monitoring Queue Depth

```elixir
:telemetry.attach(
  "queue-depth-monitor",
  [:snakepit, :pool, :status],
  fn _event, %{queue_depth: depth}, metadata, _ ->
    if depth > 50 do
      Logger.error("High queue depth detected",
        pool: metadata.pool_name,
        queue_depth: depth,
        available_workers: metadata.available_workers
      )

      # Trigger autoscaling
      MyApp.Autoscaler.scale_up(metadata.pool_name)
    end
  end,
  nil
)
```

### Distributed Tracing with Correlation IDs

```elixir
:telemetry.attach_many(
  "distributed-tracer",
  [
    [:snakepit, :pool, :queue, :enqueued],
    [:snakepit, :python, :call, :start],
    [:snakepit, :python, :call, :stop]
  ],
  fn event, measurements, %{correlation_id: id} = metadata, _ ->
    # All events for the same request share the same correlation_id
    MyApp.Tracing.record_span(id, event, measurements, metadata)
  end,
  nil
)
```

## Integration with Metrics Systems

### Prometheus

```elixir
# mix.exs
def deps do
  [
    {:snakepit, "~> 0.7"},
    {:telemetry_metrics_prometheus, "~> 1.1"}
  ]
end

# lib/myapp/telemetry.ex
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {:telemetry_metrics_prometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Pool metrics
      last_value("snakepit.pool.status.queue_depth",
        tags: [:node, :pool_name]
      ),
      last_value("snakepit.pool.status.available_workers",
        tags: [:node, :pool_name]
      ),

      # Python call metrics
      summary("snakepit.python.call.stop.duration",
        unit: {:native, :millisecond},
        tags: [:node, :pool_name, :command]
      ),
      counter("snakepit.python.call.exception.count",
        tags: [:node, :error_type]
      ),

      # Worker lifecycle
      counter("snakepit.pool.worker.spawned.count",
        tags: [:node, :pool_name]
      )
    ]
  end
end
```

### StatsD

```elixir
# mix.exs
{:telemetry_metrics_statsd, "~> 0.7"}

# In your telemetry module
children = [
  {TelemetryMetricsStatsd,
   metrics: metrics(),
   host: "statsd.local",
   port: 8125}
]
```

### OpenTelemetry

```elixir
# mix.exs
{:opentelemetry_telemetry, "~> 1.0"}

# Attach OTEL handlers
:telemetry.attach_many(
  "otel-tracer",
  [
    [:snakepit, :python, :call, :start],
    [:snakepit, :python, :call, :stop],
    [:snakepit, :python, :call, :exception]
  ],
  &OpentelemetryTelemetry.handle_event/4,
  %{span_name: "snakepit.python.call"}
)
```

## Runtime Control

### Adjusting Sampling Rates

```elixir
# Reduce to 10% sampling for high-frequency events
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)

# Apply to specific event patterns
Snakepit.Telemetry.GrpcStream.update_sampling(
  "worker_1",
  0.1,
  ["python.call.*"]
)
```

### Toggling Telemetry

```elixir
# Disable telemetry for a specific worker
Snakepit.Telemetry.GrpcStream.toggle("worker_1", false)

# Re-enable
Snakepit.Telemetry.GrpcStream.toggle("worker_1", true)
```

### Event Filtering

```elixir
# Only allow specific events
Snakepit.Telemetry.GrpcStream.update_filter("worker_1",
  allow: ["python.call.*", "python.tool.*"]
)

# Block specific events
Snakepit.Telemetry.GrpcStream.update_filter("worker_1",
  deny: ["python.memory.sampled"]
)
```

## Python API

### Basic Event Emission

```python
from snakepit_bridge import telemetry

# Emit a simple event
telemetry.emit(
    "tool.execution.start",
    {"system_time": time.time_ns()},
    {"tool": "my_tool", "operation": "predict"},
    correlation_id="abc-123"
)
```

### Span Context Manager

```python
from snakepit_bridge import telemetry

def my_tool(ctx, data):
    # Automatically emits start/stop/exception events
    with telemetry.span("tool.execution", {"tool": "my_tool"}):
        result = process_data(data)

        # Emit additional metrics within the span
        telemetry.emit(
            "tool.result_size",
            {"bytes": len(result)},
            {"tool": "my_tool"}
        )

        return result
```

### Correlation ID Propagation

```python
from snakepit_bridge import telemetry

def my_tool(ctx, data):
    # Get correlation ID from context
    correlation_id = telemetry.get_correlation_id()

    # All events within this tool will share the same correlation_id
    with telemetry.span("tool.execution", {"tool": "my_tool"}, correlation_id):
        result = do_work(data)
        return result
```

## Event Structure

All telemetry events follow the standard `:telemetry` structure:

```elixir
:telemetry.execute(
  event_name :: [atom()],           # [:snakepit, :component, :resource, :action]
  measurements :: %{atom() => number()},
  metadata :: %{atom() => term()}
)
```

### Measurements

Numeric data about the event:

```elixir
%{
  duration: 1_234_567,              # Native time units
  system_time: 1_698_234_567_890,  # System.system_time()
  queue_depth: 5,
  memory_bytes: 1_048_576
}
```

### Metadata

Contextual information about the event:

```elixir
%{
  node: :node1@localhost,          # Always included
  pool_name: :default,
  worker_id: "worker_1",
  command: "predict",
  correlation_id: "abc-123",       # For distributed tracing
  result: :success
}
```

## Performance Considerations

### Event Frequency

**High Frequency** (consider sampling):
- `[:snakepit, :python, :call, :*]` - Every command execution
- `[:snakepit, :grpc, :call, :*]` - Every gRPC call

**Medium Frequency**:
- `[:snakepit, :pool, :worker, :*]` - Worker lifecycle
- `[:snakepit, :session, :*]` - Session lifecycle

**Low Frequency**:
- `[:snakepit, :pool, :status]` - Periodic (every 5-60s)
- `[:snakepit, :python, :memory, :sampled]` - Periodic

### Sampling Strategy

```elixir
# For high-frequency events, use sampling
config :snakepit, :telemetry,
  sampling_rate: 0.1  # 10% of events

# Or sample per-worker at runtime
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)
```

### Performance Impact

- **Event emission**: ~1-5 μs
- **gRPC serialization**: ~1-2 μs
- **Validation**: ~2-3 μs
- **Total overhead**: <10 μs per event
- **CPU impact**: <1% at 100% sampling, <0.1% at 10% sampling

## Troubleshooting

### No Events Received

```elixir
# Check if telemetry is enabled
Application.get_env(:snakepit, :telemetry, [])

# List attached handlers
:telemetry.list_handlers([:snakepit, :python, :call, :stop])

# Test emission manually
:telemetry.execute(
  [:snakepit, :python, :call, :stop],
  %{duration: 1000},
  %{command: "test"}
)
```

### Handler Crashes

```elixir
# Always wrap handlers with error handling
def handle_event(event, measurements, metadata, _config) do
  try do
    actual_handler(event, measurements, metadata)
  rescue
    e ->
      Logger.error("Telemetry handler crashed: #{inspect(e)}")
  end
end
```

### High Memory Usage

Check Python telemetry queue:

```python
# In Python worker
backend = telemetry.get_backend()
if hasattr(backend, 'stream'):
    dropped = backend.stream.dropped_count
    if dropped > 0:
        logger.warning(f"Telemetry dropped {dropped} events")
```

### Performance Issues

```elixir
# Reduce sampling rate
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)

# Or disable entirely for specific workers
Snakepit.Telemetry.GrpcStream.toggle("worker_1", false)
```

## Architecture

The telemetry system consists of three main components:

1. **Event Catalog** (`Snakepit.Telemetry.Naming`) - Validates event names and prevents atom table exhaustion
2. **Metadata Safety** (`Snakepit.Telemetry.SafeMetadata`) - Sanitizes metadata from Python
3. **gRPC Stream Manager** (`Snakepit.Telemetry.GrpcStream`) - Manages bidirectional streams with Python workers

Events flow: Python → gRPC Stream → Validation → `:telemetry.execute()` → Your Handlers

## Additional Resources

- **Detailed Design**: See `docs/20251028/telemetry/00_ARCHITECTURE.md`
- **Event Catalog**: See `docs/20251028/telemetry/01_EVENT_CATALOG.md`
- **Python Integration**: See `docs/20251028/telemetry/02_PYTHON_INTEGRATION.md`
- **Client Guide**: See `docs/20251028/telemetry/03_CLIENT_GUIDE.md`
- **gRPC Stream Details**: See `docs/20251028/telemetry/04_GRPC_STREAM.md`

## License

Same as Snakepit - see LICENSE file.
