# Continuation Prompt — OpenTelemetry Upgrade Plan  
_Created: 2025-10-18_

## Mission

Extend Snakepit’s observability by turning the blueprint in `opentelemetry_upgrade_plan.md` into concrete code and documentation. Work in tight TDD loops: write or update tests first, implement, then verify. Keep correlation IDs and cross-language traces front of mind.

## Required Reading

- `docs/20251018/upgrade_path/opentelemetry_upgrade_plan.md` — roadmap for metrics, tracing, exporters, correlation IDs, rollout.
- `README_PROCESS_MANAGEMENT.md` — heartbeat context and configuration knobs you’ll expose via telemetry.
- `lib/snakepit/telemetry.ex` — current telemetry events and handlers.
- `lib/snakepit/heartbeat_monitor.ex` — heartbeat events emitted today.
- `lib/snakepit/grpc_worker.ex` — session bootstrapping, heartbeat monitor integration, future span insertion points.
- `priv/python/grpc_server.py` & `priv/python/snakepit_bridge/heartbeat.py` — Python heartbeat client and gRPC service where OTEL hooks and correlation IDs will land.
- `test/snakepit/grpc/heartbeat_end_to_end_test.exs` — end-to-end heartbeat coverage; expand it as new telemetry surfaces.
- `config/config.exs` — global heartbeat defaults; update when adding telemetry or exporter config.

## Deliverables

1. **Metrics Definition & Reporter**  
   - Create `Snakepit.TelemetryMetrics` (or equivalent) with heartbeat counters/histograms.  
   - Boot a Prometheus or StatsD reporter under supervision.  
   - Document endpoints & local usage.

2. **OpenTelemetry Bootstrap**  
   - Add OTEL deps and configure console/OTLP exporter.  
   - Bridge heartbeat events to OTEL metrics/histograms via `opentelemetry_telemetry`.  
   - Wrap `Snakepit.GRPCWorker` execution in spans; propagate context through Task Supervisor.

3. **Python Instrumentation**  
   - Add Python OTEL SDK scaffolding (async-safe).  
   - Extract gRPC metadata for correlation ID, attach to spans/logs, propagate into adapters.

4. **Correlation IDs**  
   - Generate/propagate IDs across Elixir ↔ Python via gRPC metadata.  
   - Ensure heartbeat pings include IDs where useful.

5. **Testing & Docs**  
   - Add/extend ExUnit tests: verify telemetry counters bump, correlation IDs emitted, spans created.  
   - Provide sample dashboards/curl commands in docs.  
   - Update README/process docs with instructions for running reporters/exporters.

## Constraints & Process

- **TDD**: every change starts with or updates a failing test (`mix test <target>`).  
- **Scope**: focus on heartbeat, lifecycle, and worker metrics first; other subsystems can follow later but note TODOs.  
- **Compatibility**: keep heartbeat disabled by default; reporters/OTEL should be opt-in via config.  
- **Docs**: keep `docs/20251018/upgrade_path/` as source of truth; cross-link from README as needed.  
- **Safe migrations**: no breaking config changes; provide reasonable defaults and environment guards.

## Suggested Order of Work

1. Add telemetry metrics module + Prometheus reporter (tests via `:telemetry_test_listener`).  
2. Wire heartbeat events into OTEL histogram/counter.  
3. Instrument Elixir spans & context propagation.  
4. Add correlation ID plumbing (tests in Elixir + Python harness).  
5. Integrate Python OTEL SDK & log correlation.  
6. Update docs/tests/CI scripts.

## Definition of Done

- Prometheus (or chosen reporter) exposes heartbeat metrics; tests assert counts change.  
- OTEL exporter wiring verified in dev (console output acceptable for now).  
- Correlation IDs visible in both Elixir logs/telemetry metadata and Python logs/spans.  
- Documentation updated with usage instructions and troubleshooting notes.  
- All tests green (`mix test`, relevant Python unit tests if added).
