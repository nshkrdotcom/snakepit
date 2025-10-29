# Snakepit Distributed Telemetry Architecture

**Date:** 2025-10-28
**Status:** Design Document
**Phase:** 2 - Elementary Telemetry System

---

## Problem Statement

Snakepit manages Python processes from Elixir across a distributed BEAM cluster. We need:

1. **Distributed telemetry** - Events from any node in the cluster
2. **Python-to-Elixir folding** - Python worker metrics must appear as Elixir telemetry events
3. **Standard Elixir patterns** - Use `:telemetry` library conventions
4. **Zero external dependencies** - Only standard library + `:telemetry`
5. **Client-friendly** - Applications using Snakepit can easily consume and extend

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ CLIENT APPLICATION (DSPex, your app, etc.)                       │
│                                                                   │
│ :telemetry.attach([:snakepit, :python, :call, :stop], ...)      │
│ :telemetry.attach([:snakepit, :pool, :worker, :busy], ...)      │
└────────────────────┬────────────────────────────────────────────┘
                     │ listens to
┌────────────────────▼────────────────────────────────────────────┐
│ SNAKEPIT TELEMETRY LAYER (lib/snakepit/telemetry.ex)            │
│                                                                   │
│ • Elixir → :telemetry.execute()                                 │
│ • Python → Parse & Re-emit as :telemetry                        │
│ • Distributed → Node-aware metadata                             │
└────────────────────┬────────────────────────────────────────────┘
                     │
      ┌──────────────┴──────────────┐
      │                             │
┌─────▼─────────┐         ┌─────────▼────────┐
│ ELIXIR SIDE   │         │ PYTHON SIDE      │
│               │         │                  │
│ Pool events   │◄────────┤ Telemetry        │
│ Worker events │  gRPC   │ emitter          │
│ Session events│  stderr │ (structured JSON)│
└───────────────┘         └──────────────────┘
```

---

## Design Principles

### 1. **Events Flow Upward to Elixir**

Since Snakepit is an Elixir library, ALL telemetry events are Elixir `:telemetry` events, even if they originated from Python.

**Why:**
- Clients expect to consume Elixir events
- Single integration point for monitoring
- Natural fit with BEAM supervision tree

### 2. **Python Telemetry Folding Strategy**

Python workers emit telemetry that gets captured and re-emitted by Elixir:

**Primary: gRPC Stream (Phase 2.1 - INITIAL IMPLEMENTATION)**
```protobuf
service SnakepitBridge {
  rpc StreamTelemetry(stream TelemetryEvent) returns (stream TelemetryControl);
}
```
```python
# Python sends via gRPC stream
telemetry.emit("inference.start", {"duration": 123}, ...)
# → protobuf message on gRPC stream
```
```elixir
# Elixir receives from gRPC stream, re-emits
:telemetry.execute([:snakepit, :python, :inference, :start], %{duration: 123}, ...)
```

**Why this approach:**
- ✅ Clean separation from logs
- ✅ Binary protocol (efficient)
- ✅ Bidirectional (Elixir can control sampling/filtering)
- ✅ Structured (protobuf schema)
- ✅ Leverages existing gRPC infrastructure

**Alternative: stderr (Fallback)**
```python
# Python writes to stderr
sys.stderr.write('TELEMETRY:{"event":"inference.start"}\n')
```
- Simpler, works without gRPC
- Used for non-gRPC adapters or debugging
- Less efficient but universal

### 3. **Distributed Awareness**

All events include node information:

```elixir
:telemetry.execute(
  [:snakepit, :pool, :status],
  measurements,
  %{node: node(), pool_name: :default}  # ← node() included
)
```

**Benefits:**
- Aggregate across cluster
- Debug node-specific issues
- Route-aware metrics

### 4. **Three Event Layers**

**Layer 1: Snakepit Infrastructure**
- Pool management (worker availability, queue depth)
- Worker lifecycle (spawn, terminate, restart)
- Session management (create, destroy, affinity)

**Layer 2: Python Execution** (folded back from Python)
- Command execution (start, stop, exception)
- Memory/CPU metrics from Python
- Python-specific errors

**Layer 3: Application Domain** (emitted by clients)
- DSPy predictions, searches
- Custom business logic
- NOT emitted by Snakepit, but examples provided

---

## Event Naming Convention

### Format: `[:snakepit, component, resource, action]`

**Examples:**
```elixir
# Infrastructure (Layer 1)
[:snakepit, :pool, :worker, :spawned]
[:snakepit, :pool, :worker, :terminated]
[:snakepit, :pool, :queue, :depth_changed]
[:snakepit, :session, :created]
[:snakepit, :session, :destroyed]

# Python execution (Layer 2 - folded from Python)
[:snakepit, :python, :call, :start]
[:snakepit, :python, :call, :stop]
[:snakepit, :python, :call, :exception]
[:snakepit, :python, :memory, :sampled]
[:snakepit, :python, :error, :occurred]

# gRPC bridge
[:snakepit, :grpc, :call, :start]
[:snakepit, :grpc, :stream, :message]
```

**Special: Span events follow `:start`, `:stop`, `:exception` pattern**

---

## Measurements vs Metadata

### Measurements (Numeric Data)
```elixir
%{
  duration: integer(),           # Native time units
  system_time: integer(),        # System.system_time()
  memory_bytes: integer(),
  queue_depth: integer(),
  worker_count: integer()
}
```

### Metadata (Context)
```elixir
%{
  node: node(),                  # ALWAYS include
  pool_name: atom(),
  worker_id: String.t(),
  session_id: String.t() | nil,
  command: String.t(),
  correlation_id: String.t(),    # Cross-boundary tracing
  result: :success | :error,
  error_type: atom() | String.t()
}
```

---

## Python Telemetry Protocol

### Structured stderr Format

Python workers write telemetry to stderr in this format:

```python
TELEMETRY:{json_payload}\n
```

**JSON Payload Structure:**
```json
{
  "event": "inference.start",
  "measurements": {
    "system_time": 1698234567890,
    "duration": 123456789  // optional, for stop/exception
  },
  "metadata": {
    "correlation_id": "abc-123",
    "model": "gpt-4",
    "operation": "predict"
  },
  "timestamp_ns": 1698234567890123456
}
```

### Elixir Capture & Re-emit

```elixir
defmodule Snakepit.Telemetry.PythonCapture do
  @moduledoc """
  Captures Python telemetry from stderr and re-emits as Elixir telemetry.
  """

  def parse_and_emit(stderr_line, worker_context) do
    case parse_telemetry_line(stderr_line) do
      {:ok, event, measurements, metadata} ->
        # Add Elixir context
        enriched_metadata =
          metadata
          |> Map.put(:node, node())
          |> Map.put(:worker_id, worker_context.worker_id)
          |> Map.put(:pool_name, worker_context.pool_name)

        # Re-emit as Elixir telemetry
        event_name = [:snakepit, :python | String.split(event, ".")]
        :telemetry.execute(event_name, measurements, enriched_metadata)

      :not_telemetry ->
        # Regular stderr, pass through to logs
        :ok
    end
  end

  defp parse_telemetry_line("TELEMETRY:" <> json) do
    case Jason.decode(json) do
      {:ok, %{"event" => event, "measurements" => m, "metadata" => meta}} ->
        {:ok, event, atomize_keys(m), atomize_keys(meta)}
      _ ->
        :not_telemetry
    end
  end
  defp parse_telemetry_line(_), do: :not_telemetry
end
```

---

## Client Integration

### Simple Attachment

```elixir
# In your application supervision tree or config
:telemetry.attach(
  "my-app-snakepit-monitor",
  [:snakepit, :python, :call, :stop],
  &MyApp.Telemetry.handle_python_call/4,
  nil
)

defmodule MyApp.Telemetry do
  require Logger

  def handle_python_call(event, measurements, metadata, _config) do
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

### Forwarding to External Systems

```elixir
# Forward to Prometheus, StatsD, etc.
:telemetry.attach_many(
  "prometheus-exporter",
  [
    [:snakepit, :pool, :worker, :spawned],
    [:snakepit, :python, :call, :stop]
  ],
  &TelemetryMetricsPrometheus.handle_event/4,
  nil
)
```

### Custom Aggregation

```elixir
defmodule MyApp.SnakepitMetrics do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    # Attach to multiple Snakepit events
    :telemetry.attach_many(
      "my-app-aggregator",
      [
        [:snakepit, :python, :call, :stop],
        [:snakepit, :pool, :queue, :depth_changed]
      ],
      &handle_event/4,
      nil
    )

    {:ok, state}
  end

  def handle_event([:snakepit, :python, :call, :stop], measurements, metadata, _) do
    # Track average duration, 95th percentile, etc.
    GenServer.cast(__MODULE__, {:record_duration, measurements.duration, metadata})
  end

  def handle_event([:snakepit, :pool, :queue, :depth_changed], measurements, _, _) do
    # Track max queue depth
    GenServer.cast(__MODULE__, {:record_queue_depth, measurements.queue_depth})
  end
end
```

---

## Distributed Considerations

### Cross-Node Aggregation

Telemetry is **local per node** by design. For cluster-wide visibility:

**Option 1: Central Collector**
```elixir
# On each node, forward to a central GenServer
:telemetry.attach(
  "central-collector",
  [:snakepit, :pool, :status],
  fn event, measurements, metadata, _ ->
    GenServer.cast(
      {:via, Registry, {MyApp.Registry, :telemetry_collector}},
      {:event, node(), event, measurements, metadata}
    )
  end,
  nil
)
```

**Option 2: External System**
- Prometheus scrapes each node's `/metrics` endpoint
- StatsD receives from all nodes
- OpenTelemetry collector aggregates

**Option 3: Application Layer**
- Each node reports to shared ETS table (if using :pg or horde)
- Application queries all nodes and aggregates

---

## Performance Considerations

### Event Frequency

**High frequency** (every call):
- `[:snakepit, :python, :call, :start|stop]`
- `[:snakepit, :grpc, :call, :start|stop]`

**Medium frequency** (worker lifecycle):
- `[:snakepit, :pool, :worker, :spawned|terminated]`
- `[:snakepit, :session, :created|destroyed]`

**Low frequency** (status snapshots):
- `[:snakepit, :pool, :status]` (periodic)
- `[:snakepit, :python, :memory, :sampled]` (periodic)

### Sampling Strategy

For high-frequency events, consider sampling:

```elixir
# Sample 10% of python calls
if :rand.uniform(100) <= 10 do
  :telemetry.execute([:snakepit, :python, :call, :stop], measurements, metadata)
end
```

Or make it configurable:

```elixir
config :snakepit, :telemetry,
  sampling_rate: 0.1  # 10%
```

---

## Configuration

### Telemetry Toggles

```elixir
config :snakepit, :telemetry,
  enabled: true,                    # Master toggle
  python_telemetry: true,           # Capture Python stderr telemetry
  pool_events: true,                # Pool/worker lifecycle
  command_events: true,             # Per-command execution
  sampling_rate: 1.0                # 1.0 = 100%, 0.1 = 10%
```

### Event Filtering

```elixir
config :snakepit, :telemetry,
  excluded_events: [
    [:snakepit, :pool, :status]     # Don't emit periodic status
  ]
```

---

## Implementation Phases

### Phase 2.1: Core Infrastructure (This PR)
- [x] Design architecture
- [ ] Implement `Snakepit.Telemetry` module
- [ ] Add pool/worker lifecycle events
- [ ] Add command execution events
- [ ] Python stderr capture parser
- [ ] Configuration system
- [ ] Basic tests

### Phase 2.2: Python Integration
- [ ] Python telemetry emitter helper
- [ ] Memory/CPU periodic polling
- [ ] Error telemetry
- [ ] gRPC metadata propagation
- [ ] Correlation ID plumbing

### Phase 2.3: Client Tools
- [ ] Helper macros for common patterns
- [ ] Example integrations (Prometheus, Logger)
- [ ] Performance dashboard queries
- [ ] Testing utilities

---

## References

- [Elixir Telemetry](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [OpenTelemetry Erlang](https://opentelemetry.io/docs/erlang/)

---

**Next:** [01_EVENT_CATALOG.md](./01_EVENT_CATALOG.md) - Complete event specifications
