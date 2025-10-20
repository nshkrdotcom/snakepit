# Snakepit 0.6.1 Deep Dive: Heartbeats, Correlation, and Observability

This document captures a full technical review of the functionality added after the `v0.6.0` tag, with a special focus on the heartbeat subsystem and request correlation plumbing. All references below point at the current `main` head.

## Additions Since v0.6.0 (Overview)
- **Configurable logging facade** via `Snakepit.Logger`, wired through all core supervisors, workers, and pool infrastructure for consistent log suppression and leveled output (`lib/snakepit/logger.ex`, `lib/snakepit/application.ex:52`, `lib/snakepit/grpc_worker.ex:272`).
- **Heartbeat support** baked into gRPC workers, including per-worker configuration, telemetry emission, and port process management (`lib/snakepit/grpc_worker.ex:212`, `lib/snakepit/heartbeat_monitor.ex`).
- **Correlation identifiers** automatically generated and propagated across request call paths, telemetry metadata, and OpenTelemetry spans (`lib/snakepit/telemetry/correlation.ex`, `lib/snakepit/grpc_worker.ex:470`).
- **Observability stack**: Prometheus metric definitions (`lib/snakepit/telemetry_metrics.ex`), OTLP bootstrapper (`lib/snakepit/telemetry/open_telemetry.ex`), plus end-to-end OpenTelemetry span wiring inside the gRPC worker (`lib/snakepit/grpc_worker.ex:1099`).
- **Example and config hygiene**: demos now disable verbose logging by default, and multi-pool heartbeat defaults ship in `config/config.exs:9`.

## Heartbeat System Deep Dive

### Configuration Surface
- Global defaults live under `:snakepit, :heartbeat` (`config/config.exs:49`) and are pulled via `Snakepit.Config.heartbeat_defaults/0`.
- Per-worker overrides are accepted as `%{heartbeat: %{...}}` inside worker configuration maps. `Snakepit.GRPCWorker` normalizes them through `normalize_heartbeat_config/1` before instantiating monitors (`lib/snakepit/grpc_worker.ex:864`).
- Supported options (all optional): `enabled`, `ping_interval_ms`, `timeout_ms`, `max_missed_heartbeats`, `initial_delay_ms`, `ping_fun`, `test_pid`. Unknown keys are stripped to avoid monitor crashes (`lib/snakepit/grpc_worker.ex:868`).

### Runtime Flow
1. Worker boot reserves a slot in the `ProcessRegistry`, launches the Python gRPC process, and records its OS PID immediately (`lib/snakepit/grpc_worker.ex:235`). This prevents orphan detection races.
2. Once the Python port is healthy, `maybe_start_heartbeat_monitor/1` decides whether to spin up a `Snakepit.HeartbeatMonitor` process (`lib/snakepit/grpc_worker.ex:705`).
3. The monitor sends `ping_fun.(timestamp)` on each interval. In production the worker injects a function that invokes the adapter’s heartbeat endpoint, falling back to the generated gRPC client (`lib/snakepit/grpc_worker.ex:760`).
4. Successful responses call `HeartbeatMonitor.notify_pong/2`, which zeroes the miss counter and schedules the next ping (`lib/snakepit/heartbeat_monitor.ex:116`).
5. Monitor telemetry events broadcast `:ping_sent`, `:pong_received`, `:heartbeat_timeout`, and `:monitor_failure` with counts, latency, and failure metadata (`lib/snakepit/heartbeat_monitor.ex:204`).

### Failure Handling
- Each ping schedules a timeout; missing a pong increments `missed_heartbeats`. Crossing `max_missed_heartbeats` emits `:monitor_failure` and executes `Process.exit(worker_pid, {:shutdown, reason})` (`lib/snakepit/heartbeat_monitor.ex:233`).
- Because the worker process runs with `Process.flag(:trap_exit, true)`, termination flows through `Snakepit.GRPCWorker.terminate/2`, which:
  - Stops the monitor and notifies any test observers (`lib/snakepit/grpc_worker.ex:647`).
  - Escalates to `Snakepit.ProcessKiller.kill_with_escalation/2` for graceful SIGTERM→SIGKILL shutdowns, using the stored OS PID (`lib/snakepit/grpc_worker.ex:652`).
  - Closes the Port and unregisters the worker from the registry, guaranteeing that heartbeat-triggered exits do not leak Python processes (`lib/snakepit/grpc_worker.ex:680`).
- The ProcessRegistry keeps run identifiers for forensic cleanup (`Snakepit.Pool.ProcessRegistry.activate_worker/4` in `lib/snakepit/grpc_worker.ex:258`), so ApplicationCleanup can sweep if termination fails mid-flight.

## Testing Coverage

| Area | File | What It Verifies |
|------|------|------------------|
| Monitor core loop | `test/snakepit/heartbeat_monitor_test.exs:28` | Pings increment counters; `notify_pong/2` clears misses; exceeding `max_missed_heartbeats` exits both monitor **and** worker with `{:shutdown, :heartbeat_timeout}`. |
| Long-run stability | `test/snakepit/heartbeat_monitor_test.exs:98` | Sustained 1s run validates timers continue to reschedule and keep `missed_heartbeats` at zero. |
| Worker integration | `test/snakepit/grpc/heartbeat_integration_test.exs:24` | gRPC worker starts monitor when enabled, suppresses it when disabled, and shuts it down cleanly on worker stop. |
| End-to-end Python | `test/snakepit/grpc/heartbeat_end_to_end_test.exs:24` | Spin up real Python worker, confirm monitor attaches, receives pongs, and tears down without residue. |
| Heartbeat kill enforcement | `test/snakepit/grpc/heartbeat_end_to_end_test.exs:102` | Forces heartbeat timeout against a real Python worker, asserts monitor exit, worker shutdown, ProcessRegistry cleanup, and OS PID termination. |
| Telemetry + correlation | `test/unit/grpc/grpc_worker_telemetry_test.exs:8` | Ensures correlation IDs are always present and consistent on `execute` telemetry events. |

### Failure Mode Confirmation
- **Heartbeat timeout ➜ Worker exit ➜ External process kill**: Verified in `HeartbeatEndToEndTest` by forcing a timeout, observing the monitor crash, capturing the worker `:DOWN`, and checking that the registered Python PID is killed at the OS level.
- **Missing pong with delayed heartbeats**: The timeout path is triggered by elapsed `timeout_ms` regardless of ping cadence. Tests cover the case where `ping_fun` returns `:ok` but no pong arrives—the monitor still enforces the threshold.
- **Monitor teardown on manual stop**: Integration tests assert monitors receive `{:heartbeat_monitor_stopped, id, reason}` on worker shutdown, guarding against lingering ping timers.

## Correlation & Tracing Path
- `Snakepit.GRPCWorker` wraps all argument maps with `ensure_correlation/1`, deriving a shared `correlation_id` across string and atom keys (`lib/snakepit/grpc_worker.ex:1150`).
- The identifier originates from `Snakepit.Telemetry.Correlation.new_id/0`, a prefix-based hex token (`lib/snakepit/telemetry/correlation.ex:9`).
- Telemetry metadata contains the correlation for start/stop events, confirmed in unit tests (`test/unit/grpc/grpc_worker_telemetry_test.exs:42`).
- OpenTelemetry spans attach the correlation as an attribute (`lib/snakepit/grpc_worker.ex:1219`) and propagate status/errors via `maybe_set_span_status/2`.
- When OTLP is enabled (`config/config.exs:25`), `Snakepit.Telemetry.OpenTelemetry.setup/0` boots exporters, attaches span handlers, and emits span events on heartbeat telemetry (`lib/snakepit/telemetry/open_telemetry.ex:60`).

## Observability Surface
- Prometheus metrics are exposed through `Snakepit.TelemetryMetrics.metrics/0`, covering heartbeat, execution counts, duration summaries, and failure counters (`lib/snakepit/telemetry_metrics.ex:12`). The reporter is opt-in via config (`config/config.exs:41`).
- `Snakepit.Telemetry` (not shown above) emits worker lifecycle events consumed by both the Prometheus layer and OpenTelemetry.
- README and the new `LOG_LEVEL_CONFIGURATION.md` walk users through log suppression strategies, aligning the examples with the new logging subsystem (`README.md:109`, `LOG_LEVEL_CONFIGURATION.md`).

## Gaps & Recommendations
- **Adapter heartbeat contracts**: The default pulse uses the generated gRPC client. Adapters can override `grpc_heartbeat/3`, but we do not validate custom implementations. A behaviour + contract test could provide earlier failures.
- **Correlation propagation to Python**: The correlation ID reaches telemetry and spans, but we should document (or test) that the Python bridge injects it into structured logs (`priv/python/snakepit_bridge/telemetry.py` handles this implicitly). A pytest ensuring the header arrives would make the contract explicit.
- **Adapter heartbeat contracts**: The default pulse uses the generated gRPC client. Adapters can override `grpc_heartbeat/3`, but we do not validate custom implementations. A behaviour + contract test could provide earlier failures.
- **Correlation propagation to Python**: The correlation ID reaches telemetry and spans, but we should document (or test) that the Python bridge injects it into structured logs (`priv/python/snakepit_bridge/telemetry.py` handles this implicitly). A pytest ensuring the header arrives would make the contract explicit.

## Validation
- `mix test` (7 doctests, 170 tests, 0 failures, 3 excluded, 2 skipped).
- `mix docs` (no warnings after clearing the stale `executable_path/0` reference).

These runs ensure the heartbeat, correlation, and observability layers compile, execute, and render documentation cleanly.
