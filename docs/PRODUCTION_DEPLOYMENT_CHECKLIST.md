# Production Deployment Checklist (Snakepit v0.7.4)

Use this checklist before shipping Snakepit-backed services to production. It
covers the 0.7.4 runtime upgrades (zero-copy, crash barrier, hermetic Python,
exception translation) plus operational readiness.

---

## Pre-Deployment

### 1) Runtime Selection (Hermetic Python)

- [ ] Decide Python strategy:
  - `:uv` managed runtime (recommended for reproducibility)
  - `:system` + `SNAKEPIT_PYTHON` when using an external interpreter
- [ ] If using uv:
  ```elixir
  config :snakepit, :python,
    strategy: :uv,
    managed: true,
    python_version: "3.12.3",
    runtime_dir: "priv/snakepit/python"
  ```
- [ ] Run `mix snakepit.setup` and `mix snakepit.doctor` on the build host.
- [ ] Confirm runtime identity is present in environment metadata:
  `SNAKEPIT_PYTHON_RUNTIME_HASH`, `SNAKEPIT_PYTHON_VERSION`, `SNAKEPIT_PYTHON_PLATFORM`.

### 2) Crash Barrier & Idempotency

- [ ] Configure crash barrier to match your reliability policy:
  ```elixir
  config :snakepit, :crash_barrier,
    enabled: true,
    retry: :idempotent,
    max_retries: 1,
    taint_ms: 5_000
  ```
- [ ] Ensure calls that are safe to retry include `idempotent: true` in payloads
  (or use SnakeBridge wrappers that include it automatically).
- [ ] Confirm exit-code classifications if you rely on hardware-specific exits
  (OOM, SIGKILL, etc.).

### 3) Zero-Copy Readiness (Optional)

- [ ] Enable zero-copy only when your adapter/runtime supports it:
  ```elixir
  config :snakepit, :zero_copy, enabled: true
  ```
- [ ] Validate DLPack/Arrow support in Python (`torch`, `pyarrow`, or equivalent).
- [ ] Confirm fallback telemetry is acceptable when zero-copy is unavailable.

### 4) Telemetry & Logging

- [ ] Attach telemetry handlers for pool lifecycle, crash barrier, zero-copy,
  and exception translation events.
- [ ] Optional: enable OpenTelemetry exporter for distributed tracing.
- [ ] Set Snakepit log level for production:
  ```elixir
  config :snakepit, log_level: :warning
  ```
- [ ] Ensure log redaction is enabled for payloads (default behaviour).

### 5) Pool Sizing & Resource Limits

- [ ] Review pool size and startup batch settings.
- [ ] Configure Python thread limits to prevent fork storms:
  ```elixir
  config :snakepit, :python_thread_limits, %{openblas: 1, omp: 1, mkl: 1}
  ```
- [ ] Configure worker TTL or max requests if you need periodic recycling.

### 6) Validation & Smoke Tests

- [ ] `mix test`
- [ ] `mix dialyzer`
- [ ] `mix credo --strict`
- [ ] `mix format --check-formatted`
- [ ] `./test_python.sh`
- [ ] Run an example smoke test: `mix run --no-start examples/grpc_basic.exs`

---

## Post-Deployment

### Health Checks

- [ ] Monitor `:snakepit, :pool, :status` for queue depth and availability.
- [ ] Monitor crash barrier events (`:worker, :crash`, `:worker, :tainted`).
- [ ] Validate exception translation rates (`:python, :exception, :mapped`).

### Alerts

1. Crash barrier taint rate above threshold.
2. Queue depth > capacity for sustained window.
3. Repeated worker restarts per minute.
4. Zero-copy fallbacks spiking unexpectedly.

---

## Rollback Plan

If instability appears:
1. Disable crash barrier retries (set `retry: :never` or `max_retries: 0`).
2. Disable zero-copy (`zero_copy: [enabled: false]`).
3. Switch to system Python if uv runtime integrity is suspect.
4. Roll back to the previous Snakepit release once traffic is drained.
