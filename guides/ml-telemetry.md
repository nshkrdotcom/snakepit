# ML Telemetry

Snakepit provides comprehensive telemetry for ML workloads including
hardware detection, GPU profiling, and error tracking.

## Event Categories

### Hardware Events

```elixir
# Attach to hardware detection
:telemetry.attach(
  "hardware-handler",
  [:snakepit, :hardware, :detect, :stop],
  fn _event, %{duration: duration}, metadata, _config ->
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    IO.puts("Hardware detected in #{duration_ms}ms: #{metadata.accelerator}")
  end,
  nil
)
```

Events:
- `[:snakepit, :hardware, :detect, :start]`
- `[:snakepit, :hardware, :detect, :stop]`
- `[:snakepit, :hardware, :select, :start]`
- `[:snakepit, :hardware, :select, :stop]`

### Circuit Breaker Events

```elixir
:telemetry.attach(
  "circuit-breaker-handler",
  [:snakepit, :circuit_breaker, :opened],
  fn _event, %{failure_count: count}, %{pool: pool}, _config ->
    Logger.warning("Circuit opened for #{pool}: #{count} failures")
  end,
  nil
)
```

Events:
- `[:snakepit, :circuit_breaker, :opened]`
- `[:snakepit, :circuit_breaker, :closed]`
- `[:snakepit, :circuit_breaker, :half_open]`

### GPU Profiler Events

```elixir
:telemetry.attach(
  "gpu-handler",
  [:snakepit, :gpu, :memory, :sampled],
  fn _event, measurements, metadata, _config ->
    percent = measurements.used_mb / measurements.total_mb * 100
    IO.puts("GPU #{inspect(metadata.device)}: #{percent}% memory used")
  end,
  nil
)
```

Events:
- `[:snakepit, :gpu, :memory, :sampled]`
- `[:snakepit, :gpu, :utilization, :sampled]`
- `[:snakepit, :gpu, :temperature, :sampled]`
- `[:snakepit, :gpu, :power, :sampled]`

## GPU Profiler

The GPU profiler periodically samples GPU metrics:

```elixir
# Start profiler
{:ok, profiler} = Snakepit.Telemetry.GPUProfiler.start_link(
  interval_ms: 5000,
  enabled: true
)

# Manual sample
Snakepit.Telemetry.GPUProfiler.sample_now(profiler)

# Get stats
stats = Snakepit.Telemetry.GPUProfiler.get_stats(profiler)
# => %{sample_count: 10, last_sample_time: ..., device_count: 1}

# Enable/disable
Snakepit.Telemetry.GPUProfiler.disable(profiler)
Snakepit.Telemetry.GPUProfiler.enable(profiler)

# Change interval
Snakepit.Telemetry.GPUProfiler.set_interval(profiler, 10_000)
```

## Metrics Definitions

For Prometheus integration:

```elixir
# In your telemetry supervisor
children = [
  {TelemetryMetricsPrometheus,
   metrics: Snakepit.Telemetry.Handlers.Metrics.definitions()}
]
```

Available metrics:
- `snakepit.hardware.detect.duration` - Detection timing
- `snakepit.circuit_breaker.opened.total` - Open events
- `snakepit.gpu.memory.used_mb` - GPU memory usage
- `snakepit.errors.oom.total` - OOM errors

## Span Helper

The Span module provides convenient timing helpers:

```elixir
alias Snakepit.Telemetry.Span

# Automatic span
result = Span.span([:myapp, :operation], %{pool: :default}, fn ->
  expensive_operation()
end)

# Manual span
span_ref = Span.start_span([:myapp, :operation], %{user_id: 123})
# ... do work ...
Span.end_span(span_ref, %{result: :success})
```

## Logger Handler

Attach a logger for all ML events:

```elixir
# Attach logger
Snakepit.Telemetry.Handlers.Logger.attach()

# Events will be logged automatically
# [debug] Hardware detection completed in 5ms: accelerator=cuda platform=linux-x86_64
# [warning] Circuit breaker OPENED for pool=default: 5 failures

# Detach when done
Snakepit.Telemetry.Handlers.Logger.detach()
```
