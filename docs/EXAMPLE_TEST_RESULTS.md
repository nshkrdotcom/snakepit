# Example Test Results

**Date**: 2025-12-21
**Snakepit Version**: 0.6.11
**Python Environment**: Project virtualenv (.venv)
**Python Version**: 3.12.3
**gRPC Version**: 1.76.0
**Protobuf Version**: 6.33.0
**NumPy Version**: 2.3.4

---

## Summary

All root-level examples executed successfully using `./examples/run_all.sh` (mix run).

| Example | Status | Notes |
|---------|--------|-------|
| `examples/grpc_basic.exs` | ✅ PASS | gRPC ping/echo/add/info working |
| `examples/grpc_sessions.exs` | ✅ PASS | Session flows + stats (age/idle) |
| `examples/grpc_concurrent.exs` | ✅ PASS | Concurrency + benchmarks |
| `examples/grpc_streaming.exs` | ✅ PASS | Pool scaling + streaming note |
| `examples/grpc_streaming_demo.exs` | ✅ PASS | Streaming demo with progress chunks |
| `examples/grpc_advanced.exs` | ✅ PASS | Pipeline + recovery paths |
| `examples/stream_progress_demo.exs` | ✅ PASS | `stream_progress` callback demo |
| `examples/structured_errors.exs` | ✅ PASS | Python errors shown as legacy strings |
| `examples/telemetry_basic.exs` | ✅ PASS | Worker spawn + call telemetry |
| `examples/telemetry_advanced.exs` | ✅ PASS | Correlation IDs + sampling |
| `examples/telemetry_metrics_integration.exs` | ✅ PASS | Metrics + dashboard output |
| `examples/telemetry_monitoring.exs` | ✅ PASS | Monitoring dashboard + slow call alert |
| `examples/monitoring/telemetry_integration.exs` | ✅ PASS | Documentation-only example |
| `examples/lifecycle/ttl_recycling_demo.exs` | ✅ PASS | Telemetry handler + TTL guidance |
| `examples/threaded_profile_demo.exs` | ✅ PASS | Informational (profile overview) |
| `examples/dual_mode/gil_aware_selection.exs` | ✅ PASS | Informational (profile selection) |
| `examples/dual_mode/hybrid_pools.exs` | ✅ PASS | Informational (hybrid config) |
| `examples/dual_mode/process_vs_thread_comparison.exs` | ✅ PASS | Informational (capacity/memory) |
| `examples/bidirectional_tools_demo.exs` | ✅ PASS | Auto-exit via newline |
| `examples/bidirectional_tools_demo_auto.exs` | ✅ PASS | Auto-stop via `SNAKEPIT_DEMO_DURATION_MS=3000` |

### Standalone Projects

| Project | Status | Notes |
|---------|--------|-------|
| `examples/snakepit_showcase` | ✅ PASS | `mix run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.DemoRunner.run_all() end)'` |
| `examples/snakepit_loadtest` | ✅ PASS | `mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.BasicLoadDemo.run(10) end)'` + stress/burst/sustained |

---

## Commands Used

```bash
./examples/run_all.sh
```

---

## Not Executed (Separate Projects / Manual Runs)

- `examples/python_elixir_tools_demo.py` (requires running gRPC demo server).
