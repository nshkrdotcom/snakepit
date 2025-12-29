# Observability

This guide covers Snakepit's telemetry system for monitoring, metrics, and distributed tracing across Elixir and Python workers.

## Overview

Snakepit provides a unified observability system built on Elixir's standard `:telemetry` library. All events from both Elixir infrastructure and Python workers flow through the same interface, enabling performance monitoring, resource tracking, worker health monitoring, and distributed tracing.

Key features:

- **Python-to-Elixir Event Folding** - Python metrics appear as Elixir `:telemetry` events
- **Atom Safety** - Curated event catalog prevents atom table exhaustion
- **Runtime Control** - Adjust sampling rates and filtering without restarting workers
- **Low Overhead** - Less than 10 microseconds per event

## Telemetry Event Categories

### Pool Events ([:snakepit, :pool, :*])

```elixir
[:snakepit, :pool, :initialized]        # Pool initialization complete
[:snakepit, :pool, :status]             # Periodic pool status snapshot
[:snakepit, :pool, :queue, :enqueued]   # Request queued
[:snakepit, :pool, :queue, :dequeued]   # Request dequeued
[:snakepit, :pool, :queue, :timeout]    # Request timed out in queue
[:snakepit, :pool, :saturated]          # Pool reached capacity

[:snakepit, :pool, :worker, :spawn_started]  # Worker spawn initiated
[:snakepit, :pool, :worker, :spawned]        # Worker ready
[:snakepit, :pool, :worker, :spawn_failed]   # Worker failed to start
[:snakepit, :pool, :worker, :terminated]     # Worker terminated
[:snakepit, :pool, :worker, :restarted]      # Worker restarted
```

### gRPC Worker Events ([:snakepit, :grpc_worker, :*])

```elixir
[:snakepit, :grpc, :call, :start]       # gRPC call initiated
[:snakepit, :grpc, :call, :stop]        # gRPC call completed
[:snakepit, :grpc, :call, :exception]   # gRPC call failed

[:snakepit, :grpc, :stream, :opened]    # Stream opened
[:snakepit, :grpc, :stream, :message]   # Stream message
[:snakepit, :grpc, :stream, :closed]    # Stream closed

[:snakepit, :grpc, :connection, :established]  # Channel connected
[:snakepit, :grpc, :connection, :lost]         # Connection lost
[:snakepit, :grpc, :connection, :reconnected]  # Reconnected
```

### Python Events ([:snakepit, :python, :*])

```elixir
[:snakepit, :python, :call, :start]          # Command started
[:snakepit, :python, :call, :stop]           # Command completed
[:snakepit, :python, :call, :exception]      # Command raised exception

[:snakepit, :python, :tool, :execution, :start]      # Tool started
[:snakepit, :python, :tool, :execution, :stop]       # Tool completed
[:snakepit, :python, :tool, :execution, :exception]  # Tool failed

[:snakepit, :python, :memory, :sampled]    # Memory usage
[:snakepit, :python, :cpu, :sampled]       # CPU usage
```

## Attaching Handlers

Use `:telemetry.attach/4` or `:telemetry.attach_many/4`:

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    # Attach handlers BEFORE starting Snakepit
    :telemetry.attach(
      "python-monitor",
      [:snakepit, :python, :call, :stop],
      &MyApp.Telemetry.handle_python_call/4,
      nil
    )

    :telemetry.attach_many(
      "pool-monitor",
      [
        [:snakepit, :pool, :worker, :spawned],
        [:snakepit, :pool, :worker, :terminated]
      ],
      &MyApp.Telemetry.handle_pool_event/4,
      nil
    )

    # ... start children
  end
end
```

## Measurements and Metadata

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def handle_python_call(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration / 1_000_000

    Logger.info("Python call completed",
      command: metadata.command,
      duration_ms: duration_ms,
      worker_id: metadata.worker_id
    )

    if duration_ms > 1000 do
      Logger.warning("Slow Python call: #{metadata.command}")
    end
  end
end
```

## Logging Configuration

```elixir
config :snakepit,
  log_level: :info  # :debug | :info | :warning | :error | :none
```

### Log Categories

Fine-tune logging by category:

```elixir
config :snakepit,
  log_level: :info,
  log_categories: %{
    pool: :debug,
    worker: :info,
    grpc: :warning
  }
```

### Per-Process Log Levels

```elixir
Snakepit.Logger.set_process_level("worker_1", :debug)
Snakepit.Logger.reset_process_level("worker_1")
```

## OpenTelemetry Integration

### Configuration

```elixir
# mix.exs
{:opentelemetry_telemetry, "~> 1.0"},
{:opentelemetry_exporter, "~> 1.0"}

# config/config.exs
config :snakepit,
  opentelemetry: %{
    enabled: true,
    exporters: %{otlp: %{endpoint: "http://collector:4318"}}
  }
```

### Trace Correlation

```elixir
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

## Python Telemetry API

### telemetry.emit()

```python
from snakepit_bridge import telemetry

telemetry.emit(
    "tool.execution.stop",
    {"duration": 1234, "bytes": 5000},
    {"tool": "predict", "status": "success"},
    correlation_id="abc-123"
)
```

### telemetry.span()

Automatically emits start/stop/exception events:

```python
@tool(description="Perform inference")
def inference(self, input_data: str) -> dict:
    with telemetry.span("inference", {"model": "gpt-4"}):
        result = self.model.predict(input_data)
    return result
```

Nested spans:

```python
def complex_operation(self, data):
    with telemetry.span("complex_operation"):
        with telemetry.span("preprocessing"):
            processed = self.preprocess(data)
        with telemetry.span("inference"):
            result = self.model.predict(processed)
    return result
```

### Correlation IDs

```python
correlation_id = telemetry.new_correlation_id()
telemetry.set_correlation_id(correlation_id)
current_id = telemetry.get_correlation_id()
telemetry.reset_correlation_id()
```

## Complete Monitoring Example

```elixir
defmodule MyApp.SnakepitMonitor do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    attach_handlers()
    children = [{:telemetry_metrics_prometheus, metrics: metrics()}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp attach_handlers do
    :telemetry.attach("slow-calls", [:snakepit, :python, :call, :stop],
      fn _event, %{duration: d}, meta, _ ->
        if d / 1_000_000 > 1000 do
          Logger.warning("Slow call: #{meta.command}")
        end
      end, nil)

    :telemetry.attach("queue-depth", [:snakepit, :pool, :status],
      fn _event, %{queue_depth: depth}, meta, _ ->
        if depth > 50 do
          Logger.error("High queue depth: #{depth}")
        end
      end, nil)
  end

  defp metrics do
    [
      last_value("snakepit.pool.status.queue_depth", tags: [:pool_name]),
      last_value("snakepit.pool.status.available_workers", tags: [:pool_name]),
      summary("snakepit.python.call.stop.duration",
        unit: {:native, :millisecond}, tags: [:command]),
      counter("snakepit.python.call.exception.count", tags: [:error_type]),
      counter("snakepit.pool.worker.spawned.count", tags: [:pool_name])
    ]
  end
end
```
