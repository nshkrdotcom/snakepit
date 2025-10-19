# Opentelemetry Upgrade Plan for Snakepit Heartbeat & Worker Telemetry

_Last updated: 2025-10-18_

This document is a practical guide to move Snakepit from “raw `:telemetry` events” to a production-grade observability stack. It focuses on the heartbeat workstream but generalises to the rest of the system.

## Goals

1. **Expose actionable metrics** (counts, latency, failure ratios) for heartbeat, lifecycle, and pool throughput.
2. **Instrument traces** so an Elixir request can be correlated with Python adapter work.
3. **Support vendor-neutral export** (OTLP/Prometheus/StatsD) without rewriting instrumentation.
4. **Automate local visibility** (dev/test environments shouldn’t need external infra).
5. **Enable cross-language correlation IDs** between Elixir processes and Python logs/traces.

The remainder of this document shows how to achieve each goal, the recommended code changes, and a rollout sequence.

---

## 1. Metrics from Heartbeat & Worker Events

### Current State

- `Snakepit.HeartbeatMonitor` emits `[:snakepit, :heartbeat, …]` telemetry events with metadata `{worker_id, worker_pid, missed_heartbeats, …}`.
- Pool, lifecycle, and registry code emit limited telemetry; they log heavily but don’t expose gauges/counters.

### Plan

1. _Define metrics_ via `Telemetry.Metrics`:

   ```elixir
   # lib/snakepit/telemetry_metrics.ex
   defmodule Snakepit.TelemetryMetrics do
     import Telemetry.Metrics

     def metrics do
       [
         counter("snakepit.heartbeat.pings", tags: [:worker_id]),
         counter("snakepit.heartbeat.pongs", tags: [:worker_id]),
         counter("snakepit.heartbeat.failures", tags: [:worker_id, :failure_reason]),
         summary("snakepit.heartbeat.latency", unit: {:native, :millisecond}, tags: [:worker_id]),
         last_value("snakepit.heartbeat.missed", tags: [:worker_id])
       ]
     end
   end
   ```

2. _Attach a reporter_: choose one of

   - `TelemetryMetricsPrometheus.Core`: easiest drop-in for local dev (creates `/metrics`).
   - `TelemetryMetricsStatsd`: for StatsD/Datadog pipelines.
   - `TelemetryMetricsCloudwatch` (AWS) or similar.

3. _Supervise the reporter_:

   ```elixir
   children = [
     # existing children…
     {TelemetryMetricsPrometheus.Core, name: Snakepit.Prometheus, metrics: Snakepit.TelemetryMetrics.metrics()}
   ]
   Supervisor.start_link(children, strategy: :one_for_one)
   ```

4. _Emit additional telemetry_ in lifecycle modules (e.g., `Snakepit.Worker.LifecycleManager`) to cover recycle counts, queue depth, etc.

5. _Test locally_ by curling the metrics endpoint or feeding a StatsD sink.

---

## 2. Tracing with OpenTelemetry

### Recommended Libraries

- `opentelemetry` – core SDK.
- `opentelemetry_exporter` – OTLP exporter (Datadog, Honeycomb, Tempo, etc.).
- `opentelemetry_telemetry` – bridges `:telemetry` events to OTEL spans/metrics.
- `opentelemetry_cowboy`, `opentelemetry_grpc` (optional, for automatic instrumentation of inbound requests).

### Steps

1. **Add dependencies** to `mix.exs`:

   ```elixir
   {:opentelemetry, "~> 1.3"},
   {:opentelemetry_exporter, "~> 1.6"},
   {:opentelemetry_telemetry, "~> 1.0"},
   {:opentelemetry_grpc, "~> 0.2"} # optional
   ```

2. **Configure exporter** (dev: console, prod: OTLP):

   ```elixir
   config :opentelemetry, :processors,
     otlp: %{
       exporter: {:opentelemetry_exporter, %{endpoints: ["http://localhost:4318"]}}
     }
   ```

3. **Bridge telemetry events**:

   ```elixir
   :telemetry.attach(
     "snakepit-heartbeat-otel",
     [:snakepit, :heartbeat, :pong_received],
     &OpentelemetryTelemetry.handle_event/4,
     %{
       name: "snakepit.heartbeat.latency",
       attributes: [:worker_id],
       value: fn measurements, _metadata -> measurements[:latency_ms] end,
       aggregation: :histogram
     }
   )
   ```

   Repeat for pings/failures/etc., mapping them to OTEL counters or histograms.

4. **Create spans** for request flow:

   - Wrap `Snakepit.GRPCWorker.execute/4` with `:otel_span.start_span/2` and `:otel_span.end_span/1`.
   - Propagate context into the Task Supervisor (use `:otel_ctx.attach/1` before asynchronous work).
   - In Python, use `opentelemetry-api` to create child spans around adapter logic (see section 5 for correlation IDs).

5. **Validate** using the OTEL collector or vendors (Honeycomb, Tempo, Jaeger) to view traces.

---

## 3. Vendor-Neutral Export Strategy

### Decision Matrix

| Use Case                  | Recommendation                                           |
|---------------------------|-----------------------------------------------------------|
| Local development         | Prometheus + OTLP console exporter (minimal setup)        |
| Metrics only              | `TelemetryMetricsPrometheus.Core` or StatsD reporter      |
| Tracing + metrics         | Full OpenTelemetry with OTLP exporter                     |
| Multi-language (Elixir/Python) | OpenTelemetry (shared protocol and resource attributes) |

### Implementation Notes

- You can run both a Prometheus reporter and OpenTelemetry exporter simultaneously; `:telemetry` events fan out to all handlers.
- Keep metrics definitions in one place (`Snakepit.TelemetryMetrics`) and reuse them for Prometheus, StatsD, or OTEL aggregator.
- For production, deploy the OTEL collector as a sidecar or service; configure exporters (e.g., to Datadog, Grafana Cloud, Tempo).

---

## 4. Bootstrapping Local Visibility

1. **Prometheus**: add the reporter and use `TelemetryMetricsPrometheus.PlugExporter` to serve `/metrics`. Update README with curl instructions.
2. **Console traces**: `config :opentelemetry, :processors, otlp: %{exporter: {:opentelemetry_exporter, %{protocol: :console}}}` for simple debugging.
3. **Docker compose**: provide optional `docker-compose.yml` with Prometheus + Grafana for devs who want dashboards.
4. **Testing**: add ExUnit helpers that subscribe to telemetry for assertions (e.g., assert a heartbeat failure increments a counter).
5. **Python bridge environment**: standardise on `.venv/bin/python3` (set `SNAKEPIT_PYTHON`) and install `priv/python/requirements.txt` so workers and pytest have OTEL + gRPC available. Run `PYTHONPATH=priv/python .venv/bin/pytest priv/python/tests -q` alongside `mix test` to catch correlation regressions.

---

## 5. Correlation IDs between Elixir & Python

### Overview

- Goal: when a request flows Elixir → Python → back, we should correlate logs/traces across languages.
- Approach: generate a correlation ID (or use OTEL trace/span IDs) and propagate it through gRPC metadata and logs.

### Steps

1. **Elixir**:

   - In `Snakepit.GRPCWorker.execute/4`, before calling the adapter, create or retrieve a correlation ID (e.g., from OTEL `:otel_tracer.current_span_ctx/0`).
   - Add it to gRPC metadata: `GRPC.Metadata.put(metadata, "x-snakepit-correlation-id", id)`.

2. **Python**:

   - In `priv/python/grpc_server.py`, extract the header from `context.invocation_metadata()`.
   - Use it to:
     - Annotate OTEL spans (if using OpenTelemetry Python: `span.set_attribute("snakepit.correlation_id", id)`).
     - Add to logs (`logger.info("…", extra={"correlation_id": id})`).
     - Pass it into adapters via the session context (so user code can log it).

3. **Heartbeat pings**:

   - Optionally include `correlation_id` as part of heartbeat metadata; this is useful if you need to correlate heartbeat failures with specific workers/sessions.

4. **Testing**:

   - Integration tests should assert the header is present and that both sides log it (simulate by capturing logs).
   - If using OTEL, confirm traces show a parent-child relationship between Elixir and Python spans (requires Python OTEL instrumentation).

---

## Rollout Sequence

1. **Add Telemetry Metrics Module** (`Snakepit.TelemetryMetrics`) and Prometheus reporter.
2. **Add OpenTelemetry dependencies** and configure console exporter for dev.
3. **Bridge heartbeat events** to OTEL metrics/histograms.
4. **Add spans around `Snakepit.GRPCWorker` operations** and propagate context to Task Supervisor + Python.
5. **Instrument Python bridge with OTEL** (using `opentelemetry-sdk` and `opentelemetry-instrumentation-grpc`).
6. **Implement correlation ID propagation** (gRPC metadata + logs).
7. **Document dashboards/examples**: provide sample Grafana/Tempo dashboards in `docs/` or `examples/monitoring`.
8. **Enable in CI**: run telemetry-subscription tests during `mix test`.
9. **Toggle in production**: gradually enable OTEL exporter with sampling limits, confirm no performance regression.

---

## Appendix

- **Telemetry event reference**: `lib/snakepit/telemetry.ex`.
- **Heartbeat instrumentation**: `lib/snakepit/heartbeat_monitor.ex`.
- **Reporter examples**:
  - Prometheus: `TelemetryMetricsPrometheus.Core`.
  - StatsD: `TelemetryMetricsStatsd`.
  - Cloud specific: `TelemetryMetricsCloudwatch`, `TelemetryMetricsGoogle`.
- **OpenTelemetry resources**:
  - [hexdocs.pm/opentelemetry](https://hexdocs.pm/opentelemetry/).
  - [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/).
  - [Python OpenTelemetry SDK](https://opentelemetry.io/docs/instrumentation/python/).
- **Correlation ID patterns**:
  - [W3C Trace Context](https://www.w3.org/TR/trace-context/), used by OTEL (`traceparent`/`tracestate` headers).
  - If not using OTEL, fall back to UUIDs and custom headers (`x-snakepit-correlation-id`).

---

## Checklist Summary

- [ ] Define metrics via `Telemetry.Metrics`.
- [ ] Add Prometheus (or other) reporter to the supervision tree.
- [ ] Configure OpenTelemetry exporter (console for dev, OTLP for prod).
- [ ] Attach OTEL bridges for heartbeat events.
- [ ] Wrap GRPCWorker execution in spans, propagate context.
- [ ] Instrument Python gRPC server with OTEL SDK.
- [ ] Pass correlation IDs through gRPC metadata and logs.
- [ ] Update docs and examples for running Prometheus/Grafana or OTEL collector.
- [ ] Add tests that assert telemetry emission.

Implementing these steps will position Snakepit with first-class observability: operators can chart heartbeat health, trace slow commands, and debug issues spanning BEAM/Python boundaries. Once the infrastructure is in place, flipping `heartbeat.enabled: true` becomes far less risky because drift and failure conditions surface immediately.
