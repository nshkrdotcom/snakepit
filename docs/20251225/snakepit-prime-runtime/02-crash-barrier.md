# 02 - Crash Barrier (Fault Isolation + Tainting)

## Goal

Python worker failures must not destabilize the BEAM, and repeated crashes should be contained quickly.

## Crash Types

- **Process crashes**: segmentation fault, illegal instruction, abort
- **CUDA fatal**: driver resets, illegal memory access
- **OOM**: GPU or system memory exhaustion
- **Timeouts**: long-running calls exceeding limits

## Policy

### Tainting

If a worker crashes with a classified fatal error:

- Mark the worker as **tainted**
- Remove it from the pool
- Spawn a fresh worker if capacity allows

Optionally, taint a GPU device if the error indicates device instability.

### Retry

If a call is **idempotent**, Snakepit may retry once on a clean worker.

Idempotency is carried in the payload:

```elixir
%{idempotent: true}
```

If retries are disabled or exhausted:

```elixir
{:error, %Snakepit.Error{type: :worker_crash, message: "Python worker crashed"}}
```

## Configuration

```elixir
config :snakepit,
  crash_barrier: [
    enabled: true,
    retry_idempotent: true,
    max_retries: 1,
    taint_on_exit_codes: [139, 134],
    taint_on_error_types: ["CUDA_ERROR", "SegmentationFault"],
    taint_device_on_cuda_fatal: true
  ]
```

## Exit Code Classification (Baseline)

- `139` => SIGSEGV
- `134` => SIGABRT
- `137` => SIGKILL / OOM killer

These are extended via `taint_on_exit_codes`.

## Implementation Notes

- Worker lifecycle already runs in OS processes; extend the worker supervisor to track crash reasons.
- Add a taint registry keyed by worker id and device id.
- Ensure tainted workers are not reused for session affinity.

## Telemetry

Emit:

- `[:snakepit, :worker, :crash]` (reason, exit_code)
- `[:snakepit, :worker, :tainted]` (worker_id, device)
- `[:snakepit, :worker, :restarted]`

## Testing

- Simulate crash exit codes in unit tests.
- Integration test with a worker that triggers SIGABRT.
- Verify retry logic with idempotent flag.

