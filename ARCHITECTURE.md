# Snakepit Architecture  
_Captured for v0.6.0 (worker profiles & heartbeat workstream)_  

## Overview

Snakepit is an OTP application that brokers Python execution over gRPC. The BEAM side owns lifecycle, state, and health; Python workers stay stateless, disposable, and protocol-focused. Version 0.6.0 introduces dual worker profiles (process vs. thread), proactive recycling, and heartbeat-driven supervision, so the documentation below reflects the current tree.

## Top-Level Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             Snakepit.Supervisor                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ Base services (always on)                                                   │
│   - Snakepit.Bridge.SessionStore      - GenServer + ETS backing             │
│   - Snakepit.Bridge.ToolRegistry      - GenServer for adapter metadata      │
│                                                                             │
│ Pooling branch (when :pooling_enabled is true)                              │
│   - GRPC.Server.Supervisor (Snakepit.GRPC.Endpoint / Cowboy)                │
│   - Task.Supervisor (Snakepit.TaskSupervisor)                               │
│   - Snakepit.Pool.Registry / Worker.StarterRegistry / ProcessRegistry       │
│   - Snakepit.Pool.WorkerSupervisor (DynamicSupervisor)                      │
│   - Snakepit.Worker.LifecycleManager (GenServer)                            │
│   - Snakepit.Pool (GenServer, request router)                               │
│   - Snakepit.Pool.ApplicationCleanup (GenServer, last child)                │
└─────────────────────────────────────────────────────────────────────────────┘

Worker capsule (dynamic child of WorkerSupervisor):
┌────────────────────────────────────────────────────────────┐
│ Snakepit.Pool.WorkerStarter (:permanent Supervisor)        │
│   - Worker profile module (Snakepit.WorkerProfile.*)        │
│   - Snakepit.GRPCWorker (:transient GenServer)              │
│   - Snakepit.HeartbeatMonitor (GenServer, optional)         │
└────────────────────────────────────────────────────────────┘
```

Python processes are launched by each GRPCWorker and connect back to the BEAM gRPC endpoint for stateful operations (sessions, variables, telemetry).

## Control Plane Components (Elixir)

### `Snakepit.Application`
- Applies Python thread limits before the tree boots (prevents fork bombs with large pools).
- Starts base services, optionally the pooling branch, and records start/stop timestamps for diagnostics.

### `Snakepit.Bridge.SessionStore` (`lib/snakepit/bridge/session_store.ex`)
- GenServer + ETS pair that owns all stateful session data.
- ETS tables (`:snakepit_sessions`, `:snakepit_sessions_global_programs`) are created with read/write concurrency and decentralized counters.
- Provides TTL expiration, atomic operations, and selective cleanup for high churn pools.

### `Snakepit.Bridge.ToolRegistry`
- Tracks registered tools/adapters exposed to Python workers.
- Keeps metadata so GRPCWorker can answer `Describe` calls without touching disk.

### `Snakepit.GRPC.Endpoint`
- Cowboy-based endpoint that Python workers call for session/variable RPCs.
- Runs under `GRPC.Server.Supervisor` with tuned acceptor/backlog values to survive 200+ concurrent worker startups.

### Registries (`Snakepit.Pool.Registry`, `Snakepit.Pool.ProcessRegistry`, `Snakepit.Pool.Worker.StarterRegistry`)
- Provide O(1) lookup for worker routing, track external OS PIDs/run IDs, and ensure cleanup routines can map resources back to the current BEAM instance.
- `ProcessRegistry` uses ETS to store run IDs so `Snakepit.ProcessKiller` and `Snakepit.Pool.ApplicationCleanup` can reap orphans deterministically.
- `Pool.Registry` now keeps authoritative metadata (`worker_module`, `pool_identifier`, `pool_name`) for every worker. `Snakepit.GRPCWorker` updates the registry as soon as it boots so callers such as `Pool.extract_pool_name_from_worker_id/1` and reverse lookups never have to guess based on worker ID formats.
- Helper APIs like `Pool.Registry.fetch_worker/1` centralize `pid + metadata` lookups so higher layers (pool, bridge server, worker profiles) no longer reach into the raw `Registry` tables. This ensures metadata stays normalized and ready for diagnostics.

### `Snakepit.Pool`
- GenServer request router with queueing, session affinity, and Task.Supervisor integration.
- Starts workers concurrently on boot using async streams; runtime execution uses `Task.Supervisor.async_nolink/2` so the pool remains non-blocking.
- Emits telemetry per request lifecycle; integrates with `Snakepit.Worker.LifecycleManager` for request-count tracking.

### `Snakepit.Worker.LifecycleManager`
- Tracks worker TTLs, request counts, and optional memory thresholds.
- Builds a `%Snakepit.Worker.LifecycleConfig{}` for every worker so adapter modules, env overrides, and profile selection are explicit. Replacement workers inherit the exact same spec (minus worker_id) which prevents subtle drift during recycling.
- Monitors worker pids and triggers graceful recycling via the pool when budgets are exceeded. Memory recycling samples the BEAM `Snakepit.GRPCWorker` process via `:get_memory_usage` (not the Python child) and compares the result to `memory_threshold_mb`, emitting `[:snakepit, :worker, :recycled]` telemetry with the measured MB.
- Coordinates periodic health checks across the pool and emits telemetry (`[:snakepit, :worker, :recycled]`, etc.) for dashboards.

### `Snakepit.Pool.ApplicationCleanup`
- Last child in the pool branch; terminates first on shutdown.
- Uses `Snakepit.ProcessKiller` to terminate lingering Python processes based on recorded run IDs.
- Ensures the BEAM exits cleanly even if upstream supervisors crash.

## Execution Capsule (Per Worker)

### `Snakepit.Pool.WorkerStarter`
- Permanent supervisor that owns a transient worker.
- Provides a hook to extend the capsule with additional children (profilers, monitors, etc.).
- Makes restarts local: killing the starter tears down the worker, heartbeat monitor, and any profile-specific state atomically.

### Worker profiles (`Snakepit.WorkerProfile.*`)
- Abstract the strategy for request capacity:
  - `Process` profile: one request per Python process (`capacity = 1`).
  - `Thread` profile: multi-request concurrency inside a single Python process.
- Profiles decide how to spawn/stop workers and how to report health/capacity back to the pool.

### `Snakepit.GRPCWorker`
- GenServer that launches the Python gRPC server, manages the Port, and bridges execute/stream calls.
- Maintains worker metadata (run ID, OS PID, adapter options) and cooperates with LifecycleManager/HeartbeatMonitor for health.
- Interacts with registries for lookup and with `Snakepit.ProcessKiller` for escalation on shutdown.

### `Snakepit.HeartbeatMonitor`
- Optional GenServer started per worker based on pool configuration.
- Periodically invokes a ping callback (usually a gRPC health RPC) and tracks missed responses.
- Signals the WorkerStarter (by exiting the worker) when thresholds are breached, allowing the supervisor to restart the capsule.
- `dependent: true` (default) means heartbeat failures terminate the worker; `dependent: false` keeps the worker alive and simply logs/retries so you can debug without killing the Python process.
- Heartbeat settings are shipped to Python via the `SNAKEPIT_HEARTBEAT_CONFIG` environment variable. Python workers treat it as hints (ping interval, timeout, dependent flag) so both sides agree on policy. Today this is a push-style ping from Elixir into Python; future control-plane work will layer richer distributed health signals on top.

### `Snakepit.ProcessKiller`
- Utility module for POSIX-compliant termination of external processes.
- Provides `kill_with_escalation/1` semantics (SIGTERM → SIGKILL) and discovery helpers (`kill_by_run_id/1`).
- Used by ApplicationCleanup, LifecycleManager, and GRPCWorker terminate callbacks.
- Rogue cleanup is intentionally scoped: only commands containing `grpc_server.py` or `grpc_server_threaded.py` **and** a `--snakepit-run-id/--run-id` marker are eligible. Operators can disable the startup sweep via `config :snakepit, :rogue_cleanup, enabled: false` when sharing hosts with third-party services.

### Kill Chain Summary

1. `Snakepit.Pool` enqueues the client request and picks a worker.
2. `Snakepit.GRPCWorker` executes the adapter call, keeps registry metadata fresh, and reports lifecycle stats.
3. `Snakepit.Worker.LifecycleManager` watches TTL/request/memory budgets and asks the appropriate profile to recycle workers when necessary.
4. `Snakepit.Pool.ProcessRegistry` persists run IDs + OS PIDs so BEAM restarts can see orphaned Python processes.
5. `Snakepit.ProcessKiller` and `Snakepit.Pool.ApplicationCleanup` reap any remaining processes that belong to older run IDs before the VM exits.

## Python Bridge

- `priv/python/grpc_server.py`: Stateless gRPC service that exposes Snakepit functionality to user adapters. It forwards session operations to Elixir and defers telemetry to the BEAM.
- `priv/python/snakepit_bridge/session_context.py`: Client helper that caches variables locally with TTL invalidation and knows how to signal heartbeats back to Elixir (in progress for the heartbeat workstream).
- `priv/python/snakepit_bridge/adapters/*`: User-defined logic; receives a `SessionContext` and uses generated stubs from `snakepit_bridge.proto`.
- Python code is bundled with the release; regeneration happens via `make proto-python` or `priv/python/generate_grpc.sh`.

## Observability & Telemetry

- `Snakepit.Telemetry` defines events for worker lifecycle, pool throughput, queue depth, and heartbeat outcomes. `Snakepit.TelemetryMetrics.metrics/0` feeds Prometheus via `TelemetryMetricsPrometheus.Core` once `config :snakepit, telemetry_metrics: %{prometheus: %{enabled: true}}` is set. By default metrics remain disabled so unit tests can run without a reporter.
- `Snakepit.Telemetry.OpenTelemetry` boots spans when `config :snakepit, opentelemetry: %{enabled: true}`. Local developers typically enable the console exporter (`export SNAKEPIT_OTEL_CONSOLE=true`) while CI and production point `SNAKEPIT_OTEL_ENDPOINT` at an OTLP collector. The Elixir configuration honours exporter toggles (`:otlp`, `:console`) and resource attributes (`service.name`, etc.).
- Correlation IDs flow through `lib/snakepit/telemetry/correlation.ex` and are injected into gRPC metadata. The Python bridge reads the `x-snakepit-correlation-id` header, sets the active span when `opentelemetry-sdk` is available, and mirrors the ID into structured logs so traces and logs line up across languages.
- Python workers inherit the interpreter configured by `Snakepit.Adapters.GRPCPython`. Set `SNAKEPIT_PYTHON=$PWD/.venv/bin/python3` (or add the path to `config/test.exs`) so CI/dev shells use the virtualenv that contains `grpcio`, `opentelemetry-*`, and `pytest`. `PYTHONPATH=priv/python` keeps the bridge packages importable for pytest and for the runtime shims.
- Validation recipe:
  1. `mix test --color --trace` – asserts Elixir spans/metrics handlers attach and that worker start-up succeeds with OTEL deps present.
  2. `PYTHONPATH=priv/python .venv/bin/pytest priv/python/tests -q` – exercises span helpers, correlation filters, and the threaded bridge parity tests.
  3. (Optional) `curl http://localhost:9568/metrics` – once Prometheus is enabled, confirms heartbeat counters and pool gauges surface to `/metrics`.

## Design Principles (Current)

1. **Stateless Python Workers** – All durable state lives in `Snakepit.Bridge.SessionStore`; Python can be restarted at will.
2. **Layered Supervision** – Control-plane supervisors manage pools and registries, while WorkerStarter encapsulates per-worker processes.
3. **Config-Driven Behaviour** – Pooling can be disabled (tests), heartbeat tuning lives in config maps, and worker profiles are pluggable.
4. **Proactive Health Management** – Heartbeats, lifecycle recycling, and deterministic kill routines keep long-running clusters stable.
5. **O(1) Routing & Concurrency** – Registries and ETS deliver constant-time lookup so the pool stays responsive at high request volume.

## Worker Lifecycle (Happy Path)

1. Pool boot requests `size` workers from `WorkerSupervisor`.
2. `WorkerStarter` launches the configured profile and creates a GRPCWorker.
3. GRPCWorker spawns the Python process, registers with registries, and (optionally) starts a HeartbeatMonitor.
4. LifecycleManager begins tracking TTL/request budgets.
5. Requests flow: `Snakepit.Pool` → `Task.Supervisor` → GRPCWorker → Python.
6. Completion events increment lifecycle counters; heartbeats maintain health status.
7. Recycling or heartbeat failures call back into the pool to spin up a fresh capsule.

## Protocol Overview

- gRPC definitions live in `priv/proto/snakepit_bridge.proto`.
- Core RPCs: `Execute`, `ExecuteStream`, `RegisterTool`, `GetVariable`, `SetVariable`, `InitializeSession`, `CleanupSession`, `GetWorkerInfo`, `Heartbeat`.
- Binary fields are used for large payloads; Elixir encodes via ETF and Python falls back to pickle.
- Generated code is versioned in `lib/snakepit/grpc/generated/` (Elixir) and `priv/python/generated/` (Python).

## Operational Notes

- Toggle `:pooling_enabled` for integration tests or single-worker scenarios.
- Dialyzer PLTs live in `priv/plts`—run `mix dialyzer` after changing protocol or worker APIs.
- When introducing new supervisor children, update `lib/snakepit/supervisor_tree.md` and corresponding docs in `docs/20251018/`.
- Always regenerate gRPC stubs in lockstep (`mix grpc.gen`, `make proto-python`) before cutting a release.
