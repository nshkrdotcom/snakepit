# Snakepit Telemetry Events

Comprehensive reference for all telemetry events emitted by Snakepit v0.7.4+.

## Overview

Snakepit uses `:telemetry` for observability and monitoring. Events are emitted at key lifecycle points to enable:
- Performance monitoring
- Resource tracking
- Worker health monitoring
- Automatic recycling visibility
- Custom metrics and alerts

## Event List

### Worker Lifecycle Events

#### `[:snakepit, :worker, :recycled]`

Emitted when a worker is recycled (TTL, max requests, memory threshold).

**Measurements:**
- `count: 1` - Always 1 per event

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  reason: :ttl_expired | :max_requests | :memory_threshold | :manual | :worker_died,
  uptime_seconds: 3600,
  request_count: 1234
}
```

**Example Handler:**
```elixir
:telemetry.attach(
  "worker-recycle-handler",
  [:snakepit, :worker, :recycled],
  fn _event, %{count: count}, metadata, _config ->
    Logger.info("Worker #{metadata.worker_id} recycled: #{metadata.reason}")
    Logger.info("  Uptime: #{metadata.uptime_seconds}s, Requests: #{metadata.request_count}")
  end,
  nil
)
```

#### `[:snakepit, :worker, :health_check_failed]`

Emitted when a worker fails a health check.

**Measurements:**
- `count: 1`

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  reason: :worker_dead | :health_check_failed | term()
}
```

#### `[:snakepit, :worker, :started]`

Emitted when a worker successfully starts (future enhancement).

**Measurements:**
- `count: 1`
- `startup_time_ms: integer()`

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  profile: :process | :thread,
  capacity: 1 | 16  # Depends on profile
}
```

#### `[:snakepit, :worker, :crash]`

Emitted when a worker crash is detected and classified by the crash barrier.

**Measurements:**
- (none)

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  reason: term(),
  exit_code: integer() | nil,
  device: :cuda | nil
}
```

#### `[:snakepit, :worker, :tainted]`

Emitted when a worker is tainted after a crash.

**Measurements:**
- `duration_ms: integer()` - Taint duration

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  reason: term(),
  exit_code: integer() | nil,
  device: :cuda | nil
}
```

#### `[:snakepit, :worker, :restarted]`

Emitted when a tainted worker is restarted.

**Measurements:**
- (none)

**Metadata:**
```elixir
%{
  worker_id: "pool_worker_123",
  pool: :hpc_pool,
  reason: term(),
  exit_code: integer() | nil,
  device: :cuda | nil
}
```

---

### Zero-Copy Events

#### `[:snakepit, :zero_copy, :export]`

Emitted when a zero-copy handle is exported.

**Measurements:**
- `duration_ms: float()`
- `bytes: integer()` - Payload size when available

**Metadata:**
```elixir
%{
  kind: :dlpack | :arrow,
  device: :cpu | :cuda | term(),
  dtype: atom() | String.t(),
  shape: tuple() | list()
}
```

#### `[:snakepit, :zero_copy, :import]`

Emitted when a zero-copy handle is imported.

**Measurements:**
- `duration_ms: float()`
- `bytes: integer()` - Payload size when available

**Metadata:**
```elixir
%{
  kind: :dlpack | :arrow,
  device: :cpu | :cuda | term(),
  dtype: atom() | String.t(),
  shape: tuple() | list()
}
```

#### `[:snakepit, :zero_copy, :fallback]`

Emitted when zero-copy is unavailable and a copy fallback is used.

**Measurements:**
- `duration_ms: float()`
- `bytes: integer()` - Payload size when available

**Metadata:**
```elixir
%{
  kind: :dlpack | :arrow,
  device: :cpu | :cuda | term(),
  dtype: atom() | String.t(),
  shape: tuple() | list()
}
```

### Python Exception Translation

#### `[:snakepit, :python, :exception, :mapped]`

Emitted when a Python exception is mapped to a specific `Snakepit.Error.*` struct.

**Measurements:**
- (none)

**Metadata:**
```elixir
%{
  python_type: "ValueError",
  library: "numpy",
  function: "mean"
}
```

#### `[:snakepit, :python, :exception, :unmapped]`

Emitted when a Python exception falls back to `Snakepit.Error.PythonException`.

**Measurements:**
- (none)

**Metadata:**
```elixir
%{
  python_type: "CustomError",
  library: "custom_lib",
  function: "run"
}
```

---

### Pool Events (Future)

#### `[:snakepit, :pool, :saturated]`

Emitted when pool reaches capacity and queues requests.

**Measurements:**
- `count: 1`
- `queue_size: integer()`

**Metadata:**
```elixir
%{
  pool: :hpc_pool,
  available_workers: 0,
  busy_workers: 16,
  queue_size: 42
}
```

#### `[:snakepit, :request, :executed]`

Emitted after each successful request.

**Measurements:**
- `count: 1`
- `duration_us: integer()` (microseconds)

**Metadata:**
```elixir
%{
  pool: :hpc_pool,
  worker_id: "pool_worker_123",
  command: "compute_intensive",
  success: true | false
}
```

---

## Usage Examples

### Basic Monitoring

```elixir
# Attach handler for all Snakepit events
:telemetry.attach_many(
  "snakepit-monitor",
  [
    [:snakepit, :worker, :recycled],
    [:snakepit, :worker, :health_check_failed]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)

defmodule MyApp.TelemetryHandler do
  def handle_event(event, measurements, metadata, _config) do
    IO.inspect({event, measurements, metadata}, label: "Snakepit Event")
  end
end
```

### Prometheus Metrics

```elixir
# Count worker recycling events by reason
:telemetry.attach(
  "worker-recycle-counter",
  [:snakepit, :worker, :recycled],
  fn _event, _measurements, metadata, _config ->
    :telemetry_metrics_prometheus_core.execute(
      :counter,
      [:snakepit, :worker_recycled_total],
      1,
      %{reason: metadata.reason, pool: metadata.pool}
    )
  end,
  nil
)

# Track worker uptime histogram
:telemetry.attach(
  "worker-uptime-histogram",
  [:snakepit, :worker, :recycled],
  fn _event, _measurements, metadata, _config ->
    :telemetry_metrics_prometheus_core.execute(
      :histogram,
      [:snakepit, :worker_uptime_seconds],
      metadata.uptime_seconds,
      %{pool: metadata.pool}
    )
  end,
  nil
)
```

### LiveDashboard Integration

```elixir
# In router.ex
live_dashboard "/dashboard",
  metrics: MyApp.Telemetry,
  telemetry_poller_metrics: [
    # Snakepit metrics
    last_value("snakepit.worker.count"),
    counter("snakepit.worker.recycled_total"),
    summary("snakepit.worker.uptime_seconds"),
    last_value("snakepit.pool.queue_size")
  ]
```

### Custom Alerts

```elixir
# Alert if too many workers recycled in short time
:telemetry.attach(
  "worker-recycle-alert",
  [:snakepit, :worker, :recycled],
  fn _event, _measurements, metadata, state ->
    # Increment counter
    count = Map.get(state, :recycle_count, 0) + 1
    new_state = Map.put(state, :recycle_count, count)

    # Alert if > 10 recycling events in 60 seconds
    if count > 10 do
      Logger.warning("High worker churn detected: #{count} workers recycled")
      # Send alert to monitoring system
      MyApp.Monitoring.send_alert(:high_worker_churn, metadata)
    end

    new_state
  end,
  %{}
)
```

---

## Telemetry Best Practices

### 1. Attach Handlers Early

```elixir
# In application.ex, before starting Snakepit
defmodule MyApp.Application do
  def start(_type, _args) do
    # Attach telemetry handlers FIRST
    MyApp.Telemetry.attach_handlers()

    children = [
      # ... other children
      {Snakepit.Application, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### 2. Use Structured Metadata

```elixir
# Good: Structured data
:telemetry.execute(
  [:myapp, :custom, :event],
  %{count: 1},
  %{pool: pool_name, worker: worker_id}
)

# Bad: Unstructured strings
:telemetry.execute(
  [:myapp, :custom, :event],
  %{count: 1},
  %{message: "Pool #{pool_name} worker #{worker_id}"}
)
```

### 3. Don't Block in Handlers

```elixir
# Bad: Blocking I/O in handler
:telemetry.attach("handler", event, fn _event, _meas, meta, _cfg ->
  HTTPoison.post("http://metrics.example.com", Jason.encode!(meta))  # SLOW!
end, nil)

# Good: Async processing
:telemetry.attach("handler", event, fn _event, _meas, meta, _cfg ->
  Task.start(fn ->
    HTTPoison.post("http://metrics.example.com", Jason.encode!(meta))
  end)
end, nil)
```

---

## Debugging Telemetry

### See All Events

```elixir
# Attach debug handler to see all Snakepit events
:telemetry.attach_many(
  "debug-all",
  [
    [:snakepit, :worker, :recycled],
    [:snakepit, :worker, :health_check_failed],
    [:snakepit, :worker, :started],
    [:snakepit, :pool, :saturated],
    [:snakepit, :request, :executed]
  ],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata}, label: "Telemetry")
  end,
  nil
)
```

### Test Event Emission

```elixir
# Manually trigger events for testing
:telemetry.execute(
  [:snakepit, :worker, :recycled],
  %{count: 1},
  %{
    worker_id: "test_worker",
    pool: :test_pool,
    reason: :manual,
    uptime_seconds: 100,
    request_count: 50
  }
)
```

---

## References

- [`:telemetry` documentation](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [Phoenix LiveDashboard](https://hexdocs.pm/phoenix_live_dashboard/)
- [TelemetryMetricsPrometheus](https://hexdocs.pm/telemetry_metrics_prometheus_core/)
