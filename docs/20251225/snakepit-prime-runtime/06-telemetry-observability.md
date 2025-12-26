# 06 - Telemetry and Observability

## Goal

Add runtime telemetry that highlights ML-relevant behavior: data movement, worker crashes, and latency.

## New Events

### Zero-Copy

- `[:snakepit, :zero_copy, :export]`
- `[:snakepit, :zero_copy, :import]`
- `[:snakepit, :zero_copy, :fallback]`

Measurements:

- `bytes` (integer)
- `duration_ms` (float)

Metadata:

- `kind` (:dlpack | :arrow)
- `device` (:cpu | :cuda | :mps)
- `dtype`
- `shape`

### Crash Barrier

- `[:snakepit, :worker, :crash]`
- `[:snakepit, :worker, :tainted]`
- `[:snakepit, :worker, :restarted]`

Metadata:

- `worker_id`
- `exit_code`
- `reason`
- `device`

### Exception Translation

- `[:snakepit, :python, :exception, :mapped]`
- `[:snakepit, :python, :exception, :unmapped]`

Metadata:

- `python_type`
- `library`
- `function`

## Example Handler

```elixir
:telemetry.attach("snakepit-ml", [:snakepit, :zero_copy, :export], fn _evt, meas, meta, _ ->
  Logger.info("zero-copy export #{meas.bytes} bytes (#{meta.kind}/#{meta.device})")
end, nil)
```

## LiveDashboard Integration

Expose the following panels:

- Active workers and tainted workers
- Zero-copy throughput (bytes/sec)
- Python call latency (p50/p95)
- Worker crash counts by reason

