# Client Telemetry Integration Guide

**Date:** 2025-10-28
**Status:** Design Document

How applications using Snakepit consume and extend telemetry.

---

## Overview

Applications using Snakepit can:
1. **Listen** to Snakepit's telemetry events
2. **Aggregate** metrics across the cluster
3. **Forward** to external systems (Prometheus, OpenTelemetry, etc.)
4. **Extend** with application-specific events

---

## Basic Integration

### 1. Attach Event Handlers

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Attach telemetry handlers during application startup
    attach_telemetry_handlers()

    children = [
      # ... your supervision tree ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp attach_telemetry_handlers do
    # Simple logger handler
    :telemetry.attach(
      "myapp-python-logger",
      [:snakepit, :python, :call, :stop],
      &MyApp.Telemetry.handle_python_call/4,
      nil
    )

    # Monitor queue depth
    :telemetry.attach(
      "myapp-queue-monitor",
      [:snakepit, :pool, :status],
      &MyApp.Telemetry.handle_pool_status/4,
      nil
    )

    # Track worker restarts
    :telemetry.attach(
      "myapp-restart-tracker",
      [:snakepit, :pool, :worker, :restarted],
      &MyApp.Telemetry.handle_worker_restart/4,
      nil
    )
  end
end
```

### 2. Handle Events

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def handle_python_call(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration / 1_000_000

    if duration_ms > 1000 do
      Logger.warning("Slow Python call detected",
        command: metadata.command,
        duration_ms: duration_ms,
        worker_id: metadata.worker_id,
        node: metadata.node
      )
    end
  end

  def handle_pool_status(_event, measurements, metadata, _config) do
    if measurements.queue_depth > 50 do
      Logger.error("High queue depth detected",
        pool: metadata.pool_name,
        queue_depth: measurements.queue_depth,
        available: measurements.available_workers,
        busy: measurements.busy_workers,
        node: metadata.node
      )

      # Maybe trigger autoscaling
      MyApp.Autoscaler.scale_up(metadata.pool_name)
    end
  end

  def handle_worker_restart(_event, measurements, metadata, _config) do
    if measurements.restart_count > 5 do
      Logger.critical("Worker restarting frequently",
        worker_id: metadata.worker_id,
        restart_count: measurements.restart_count,
        reason: metadata.reason,
        node: metadata.node
      )

      # Alert ops team
      MyApp.Alerts.send_alert(:worker_flapping, metadata)
    end
  end
end
```

---

## Advanced Patterns

### Distributed Aggregation (Cluster-Wide Metrics)

```elixir
defmodule MyApp.ClusterMetrics do
  use GenServer

  @moduledoc """
  Aggregates telemetry across all nodes in the cluster.
  """

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: {:global, __MODULE__})
  end

  def get_cluster_stats do
    GenServer.call({:global, __MODULE__}, :get_stats)
  end

  # Server Implementation

  def init(state) do
    # Attach to Snakepit events on this node
    :telemetry.attach_many(
      "cluster-metrics-collector",
      [
        [:snakepit, :pool, :status],
        [:snakepit, :python, :call, :stop],
        [:snakepit, :pool, :worker, :spawned]
      ],
      &handle_event/4,
      nil
    )

    # Start periodic sync with other nodes
    schedule_sync()

    {:ok, initial_state()}
  end

  def handle_event([:snakepit, :pool, :status], measurements, metadata, _) do
    GenServer.cast(
      {:global, __MODULE__},
      {:record_pool_status, metadata.node, metadata.pool_name, measurements}
    )
  end

  def handle_event([:snakepit, :python, :call, :stop], measurements, metadata, _) do
    duration_ms = measurements.duration / 1_000_000

    GenServer.cast(
      {:global, __MODULE__},
      {:record_call_duration, metadata.node, metadata.pool_name, duration_ms}
    )
  end

  def handle_event([:snakepit, :pool, :worker, :spawned], _measurements, metadata, _) do
    GenServer.cast(
      {:global, __MODULE__},
      {:increment_worker_count, metadata.node, metadata.pool_name}
    )
  end

  # Store metrics per node
  def handle_cast({:record_pool_status, node, pool, measurements}, state) do
    new_state =
      state
      |> put_in([:nodes, node, :pools, pool, :queue_depth], measurements.queue_depth)
      |> put_in([:nodes, node, :pools, pool, :available], measurements.available_workers)
      |> put_in([:nodes, node, :pools, pool, :busy], measurements.busy_workers)

    {:noreply, new_state}
  end

  def handle_cast({:record_call_duration, node, pool, duration_ms}, state) do
    # Track average, min, max, p95, etc.
    new_state = update_duration_stats(state, node, pool, duration_ms)
    {:noreply, new_state}
  end

  def handle_call(:get_stats, _from, state) do
    # Compute cluster-wide aggregates
    cluster_stats = %{
      total_workers: count_total_workers(state),
      total_queue_depth: sum_queue_depths(state),
      avg_call_duration: compute_avg_duration(state),
      nodes: map_size(state.nodes),
      per_node: state.nodes
    }

    {:reply, cluster_stats, state}
  end

  defp initial_state do
    %{
      nodes: %{},
      last_sync: System.monotonic_time()
    }
  end

  defp schedule_sync do
    Process.send_after(self(), :sync, 5_000)  # Every 5s
  end
end
```

---

## Forwarding to External Systems

### Prometheus Integration

```elixir
# mix.exs
def deps do
  [
    {:snakepit, "~> 0.6.7"},
    {:telemetry_metrics_prometheus, "~> 1.1"}
  ]
end
```

```elixir
# lib/myapp/telemetry.ex
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      # Prometheus exporter
      {:telemetry_metrics_prometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Snakepit pool metrics
      last_value("snakepit.pool.status.queue_depth",
        tags: [:node, :pool_name],
        description: "Current pool queue depth"
      ),

      last_value("snakepit.pool.status.available_workers",
        tags: [:node, :pool_name],
        description: "Available workers"
      ),

      last_value("snakepit.pool.status.busy_workers",
        tags: [:node, :pool_name],
        description: "Busy workers"
      ),

      # Python call metrics
      summary("snakepit.python.call.stop.duration",
        unit: {:native, :millisecond},
        tags: [:node, :pool_name, :command],
        description: "Python call duration"
      ),

      counter("snakepit.python.call.exception.count",
        tags: [:node, :pool_name, :error_type],
        description: "Python exceptions"
      ),

      # Worker lifecycle
      counter("snakepit.pool.worker.spawned.count",
        tags: [:node, :pool_name],
        description: "Workers spawned"
      ),

      counter("snakepit.pool.worker.terminated.count",
        tags: [:node, :pool_name, :reason],
        description: "Workers terminated"
      ),

      # Memory metrics (from Python)
      last_value("snakepit.python.memory.sampled.rss_bytes",
        tags: [:node, :worker_id],
        description: "Python process RSS memory"
      )
    ]
  end
end
```

### StatsD Integration

```elixir
# mix.exs
{:telemetry_metrics_statsd, "~> 0.7"}
```

```elixir
defmodule MyApp.Telemetry do
  use Supervisor

  def init(_arg) do
    children = [
      {TelemetryMetricsStatsd, metrics: metrics(), host: "statsd.local"}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Same metrics as Prometheus example
      # StatsD will automatically format them
    ]
  end
end
```

### OpenTelemetry Integration

```elixir
# mix.exs
{:opentelemetry_telemetry, "~> 1.0"}
```

```elixir
defmodule MyApp.Telemetry do
  def attach_otel_handlers do
    # Span-based tracing
    :telemetry.attach_many(
      "otel-tracer",
      [
        [:snakepit, :python, :call, :start],
        [:snakepit, :python, :call, :stop],
        [:snakepit, :python, :call, :exception]
      ],
      &OpentelemetryTelemetry.handle_event/4,
      %{
        span_name: "snakepit.python.call",
        trace_id_key: :correlation_id
      }
    )
  end
end
```

---

## Custom Metrics

### Track Application-Specific Metrics

```elixir
defmodule MyApp.DSPyMetrics do
  @moduledoc """
  Application-specific metrics on top of Snakepit telemetry.
  """

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    # Listen to Python calls and track DSPy-specific operations
    :telemetry.attach(
      "dspy-predict-tracker",
      [:snakepit, :python, :call, :stop],
      fn _event, measurements, metadata, _ ->
        # Filter for DSPy predict operations
        if String.starts_with?(metadata.command, "dspy.predict") do
          GenServer.cast(__MODULE__, {:record_predict, measurements, metadata})
        end
      end,
      nil
    )

    {:ok, initial_state()}
  end

  def handle_cast({:record_predict, measurements, metadata}, state) do
    # Track DSPy-specific metrics
    # - Prediction latency
    # - Token usage
    # - Model types
    # - Cache hit rates
    {:noreply, update_metrics(state, measurements, metadata)}
  end

  # Expose metrics
  def get_dspy_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
end
```

### Emit Your Own Events

```elixir
defmodule MyApp.BusinessLogic do
  def process_user_request(user_id, request) do
    # Your application emits its own telemetry
    :telemetry.execute(
      [:myapp, :request, :start],
      %{system_time: System.system_time()},
      %{user_id: user_id, request_type: request.type}
    )

    # Use Snakepit
    {:ok, result} = Snakepit.execute("process", request)

    # Emit completion
    :telemetry.execute(
      [:myapp, :request, :complete],
      %{duration: compute_duration()},
      %{user_id: user_id, result: :success}
    )

    result
  end
end
```

---

## Testing with Telemetry

### Unit Tests

```elixir
defmodule MyApp.FeatureTest do
  use ExUnit.Case

  test "emits telemetry on success" do
    # Attach test handler
    :telemetry.attach(
      "test-handler",
      [:snakepit, :python, :call, :stop],
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    # Execute operation
    {:ok, _result} = Snakepit.execute("my_command", %{})

    # Assert telemetry was emitted
    assert_receive {:telemetry,
      [:snakepit, :python, :call, :stop],
      measurements,
      metadata
    }

    assert measurements.duration > 0
    assert metadata.command == "my_command"

    # Cleanup
    :telemetry.detach("test-handler")
  end
end
```

### Integration Tests

```elixir
defmodule MyApp.IntegrationTest do
  use ExUnit.Case

  setup do
    # Start a test telemetry collector
    {:ok, collector} = start_telemetry_collector()

    on_exit(fn ->
      stop_telemetry_collector(collector)
    end)

    {:ok, collector: collector}
  end

  test "tracks full request lifecycle", %{collector: collector} do
    # Make request
    {:ok, _result} = MyApp.handle_request(user_id: 123)

    # Verify all expected events were emitted
    events = get_collected_events(collector)

    assert Enum.any?(events, &match?([:myapp, :request, :start], &1.event))
    assert Enum.any?(events, &match?([:snakepit, :python, :call, :start], &1.event))
    assert Enum.any?(events, &match?([:snakepit, :python, :call, :stop], &1.event))
    assert Enum.any?(events, &match?([:myapp, :request, :complete], &1.event))
  end
end
```

---

## Performance Dashboard Queries

### Sample Queries (Prometheus PromQL)

```promql
# Average Python call duration by pool
rate(snakepit_python_call_stop_duration_sum[5m]) /
rate(snakepit_python_call_stop_duration_count[5m])

# Queue depth by node and pool
snakepit_pool_status_queue_depth{node="node1@host"}

# Worker restart rate
rate(snakepit_pool_worker_restarted_count[5m])

# Error rate
rate(snakepit_python_call_exception_count[5m]) /
rate(snakepit_python_call_stop_count[5m])

# P95 latency
histogram_quantile(0.95,
  rate(snakepit_python_call_stop_duration_bucket[5m])
)

# Memory usage by worker
snakepit_python_memory_sampled_rss_bytes
```

### Sample Grafana Dashboard

```json
{
  "panels": [
    {
      "title": "Python Call Rate",
      "targets": [
        {
          "expr": "rate(snakepit_python_call_stop_count[5m])"
        }
      ]
    },
    {
      "title": "Average Duration",
      "targets": [
        {
          "expr": "rate(snakepit_python_call_stop_duration_sum[5m]) / rate(snakepit_python_call_stop_duration_count[5m])"
        }
      ]
    },
    {
      "title": "Queue Depth",
      "targets": [
        {
          "expr": "snakepit_pool_status_queue_depth"
        }
      ]
    },
    {
      "title": "Worker Count",
      "targets": [
        {
          "expr": "snakepit_pool_status_available_workers + snakepit_pool_status_busy_workers"
        }
      ]
    }
  ]
}
```

---

## Real-World Example: DSPex Integration

```elixir
defmodule DSPex.Telemetry do
  @moduledoc """
  DSPex telemetry built on top of Snakepit.
  """

  def attach_handlers do
    # Track DSPy operations
    :telemetry.attach_many(
      "dspex-tracker",
      [
        [:snakepit, :python, :call, :start],
        [:snakepit, :python, :call, :stop],
        [:snakepit, :python, :call, :exception]
      ],
      &handle_dspy_operation/4,
      nil
    )
  end

  def handle_dspy_operation([:snakepit, :python, :call, :stop], measurements, metadata, _) do
    # Extract DSPy-specific information
    case parse_dspy_command(metadata.command) do
      {:predict, module_name} ->
        :telemetry.execute(
          [:dspex, :predict, :complete],
          measurements,
          Map.put(metadata, :module, module_name)
        )

      {:forward, program_name} ->
        :telemetry.execute(
          [:dspex, :forward, :complete],
          measurements,
          Map.put(metadata, :program, program_name)
        )

      :other ->
        :ok
    end
  end

  def handle_dspy_operation([:snakepit, :python, :call, :exception], measurements, metadata, _) do
    # Track DSPy failures
    :telemetry.execute(
      [:dspex, :error],
      measurements,
      metadata
    )

    # Maybe retry or alert
    if should_alert?(metadata) do
      alert_ops_team(metadata)
    end
  end

  defp parse_dspy_command(command) do
    cond do
      String.contains?(command, "predict") -> {:predict, extract_module(command)}
      String.contains?(command, "forward") -> {:forward, extract_program(command)}
      true -> :other
    end
  end
end
```

---

## Best Practices

### DO:
- ✅ Attach handlers during application startup
- ✅ Use descriptive handler IDs for easy debugging
- ✅ Aggregate metrics in GenServers for cluster visibility
- ✅ Forward to external systems for persistence
- ✅ Test telemetry emission in your tests
- ✅ Use correlation IDs for distributed tracing

### DON'T:
- ❌ Attach handlers dynamically in hot paths
- ❌ Block in telemetry handlers (keep them fast)
- ❌ Store unbounded data in telemetry handlers
- ❌ Crash in telemetry handlers (always rescue)
- ❌ Emit your own telemetry with Snakepit's namespace

---

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
# Wrap handlers with rescue
def handle_event(event, measurements, metadata, _config) do
  try do
    actual_handler(event, measurements, metadata)
  rescue
    e ->
      Logger.error("Telemetry handler crashed: #{inspect(e)}")
  end
end
```

### Performance Issues

```elixir
# Check handler execution time
def handle_event(event, measurements, metadata, _config) do
  start = System.monotonic_time()

  actual_handler(event, measurements, metadata)

  duration = System.monotonic_time() - start
  if duration > 1_000_000 do  # 1ms
    Logger.warning("Slow telemetry handler: #{duration / 1_000_000}ms")
  end
end
```

---

## Summary

Snakepit's telemetry system provides:
- **Rich events** from infrastructure and Python execution
- **Distributed awareness** (node, pool, worker context)
- **Standard Elixir patterns** (`:telemetry` library)
- **Flexible integration** (Prometheus, StatsD, OpenTelemetry, custom)
- **Extensibility** (emit your own events on top)

**Next Steps:**
1. Attach basic handlers to monitor your pools
2. Forward metrics to your monitoring system
3. Build application-specific metrics on top
4. Set up alerting for anomalies

---

**Related:**
- [00_ARCHITECTURE.md](./00_ARCHITECTURE.md) - System architecture
- [01_EVENT_CATALOG.md](./01_EVENT_CATALOG.md) - Complete event reference
- [02_PYTHON_INTEGRATION.md](./02_PYTHON_INTEGRATION.md) - Python telemetry emitter
