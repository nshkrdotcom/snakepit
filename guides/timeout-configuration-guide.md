# Timeout Configuration Guide

Snakepit includes a unified timeout architecture designed for reliability in production deployments. This guide covers timeout profiles, deadline propagation, and configuration strategies for different workloads.

---

## Table of Contents

1. [Overview](#overview)
2. [Timeout Profiles](#timeout-profiles)
3. [How Timeouts Work](#how-timeouts-work)
4. [Configuration Reference](#configuration-reference)
5. [Common Scenarios](#common-scenarios)
6. [Debugging Timeout Issues](#debugging-timeout-issues)
7. [Migration Guide](#migration-guide)

---

## Overview

### The Problem

Earlier releases had fragmented timeout configuration with 7+ independent timeout keys that didn't coordinate:

| Issue | Symptom |
|-------|---------|
| `pool_request_timeout` vs `grpc_command_timeout` confusion | Unclear which is outer, which is inner |
| Queue wait consumed budget invisibly | Inner timeouts didn't account for queue time |
| GenServer.call timeouts fired before inner timeouts | Unhandled exits instead of structured errors |

### The Solution

Snakepit now uses a **single-budget, derived deadlines** architecture:

1. **One top-level timeout budget** set at request entry
2. **Deadline propagation** tracks remaining time through the stack
3. **Inner timeouts derived** from remaining budget minus safety margins
4. **Profile-based defaults** for different deployment scenarios

---

## Timeout Profiles

Profiles provide sensible defaults for common deployment scenarios. Configure via:

```elixir
config :snakepit, timeout_profile: :production
```

### Profile Comparison

| Profile | default_timeout | stream_timeout | queue_timeout | Use Case |
|---------|-----------------|----------------|---------------|----------|
| `:balanced` | 300s (5m) | 900s (15m) | 10s | General purpose, default |
| `:production` | 300s (5m) | 900s (15m) | 10s | Production deployments |
| `:production_strict` | 60s | 300s (5m) | 5s | Latency-sensitive APIs |
| `:development` | 900s (15m) | 3600s (60m) | 60s | Local development, debugging |
| `:ml_inference` | 900s (15m) | 3600s (60m) | 60s | ML model inference |
| `:batch` | 3600s (60m) | ∞ | 300s (5m) | Batch processing jobs |

### Profile Selection Guidelines

| Workload Type | Recommended Profile | Rationale |
|---------------|---------------------|-----------|
| Web API backends | `:production_strict` | Fast failure for user-facing requests |
| Background jobs | `:batch` | Long-running operations need patience |
| ML inference | `:ml_inference` | Model loading and inference are slow |
| Development | `:development` | Generous timeouts for debugging |
| Mixed workloads | `:balanced` | Good defaults for most cases |

### Using Profiles

```elixir
# config/runtime.exs

# Production API server
config :snakepit, timeout_profile: :production_strict

# ML inference service
config :snakepit, timeout_profile: :ml_inference

# Batch processing worker
config :snakepit, timeout_profile: :batch
```

---

## How Timeouts Work

### The Timeout Stack

Requests flow through multiple layers, each with its own timeout:

```
┌─────────────────────────────────────────────────────────────────┐
│  User Code: Snakepit.execute("cmd", args, timeout: 60_000)      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Pool Layer                                                     │
│  ├─ GenServer.call timeout: 60_000                              │
│  ├─ Queue wait (if workers busy): up to queue_timeout           │
│  └─ Deadline stored: now + 60_000                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Worker Layer                                                   │
│  ├─ GenServer.call timeout: remaining - 1000ms margin           │
│  └─ Forwards to gRPC adapter                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  gRPC Layer                                                     │
│  ├─ gRPC call timeout: remaining - 1200ms total margins         │
│  └─ Actual Python execution                                     │
└─────────────────────────────────────────────────────────────────┘
```

### Margin Formula

Inner timeouts are derived from the total budget minus safety margins:

```
rpc_timeout = total_timeout - worker_call_margin_ms - pool_reply_margin_ms
```

| Margin | Default | Purpose |
|--------|---------|---------|
| `worker_call_margin_ms` | 1000ms | GenServer.call overhead to worker |
| `pool_reply_margin_ms` | 200ms | Pool reply processing overhead |

**Example**: With a 60-second total budget:
- Total: 60,000ms
- Worker margin: -1,000ms
- Pool margin: -200ms
- **RPC timeout: 58,800ms**

This ensures inner timeouts expire *before* outer GenServer.call timeouts, reducing timeout-related exits and returning structured `Snakepit.Error` tuples at public API boundaries.

### Deadline Propagation

When a request enters the pool, a deadline is computed and stored:

```elixir
# Inside Pool.execute/3
deadline_ms = System.monotonic_time(:millisecond) + timeout
opts_with_deadline = Keyword.put(opts, :deadline_ms, deadline_ms)
```

As the request moves through the stack:

1. **Queue handler** uses `effective_queue_timeout_ms/2` to respect deadline
2. **Worker execution** uses `derive_rpc_timeout_from_opts/2` to compute remaining budget
3. **All layers** return structured errors instead of crashing on timeout

### Queue-Aware Timeouts

If a request waits in queue, that time is subtracted from the budget:

```elixir
# Request with 60s budget waits 5s in queue
# Remaining budget for execution: 55s (minus margins)
```

This prevents the common bug where queue wait + execution time exceeds the user's expected timeout.

---

## Configuration Reference

### Profile-Based Configuration (Recommended)

```elixir
# config/runtime.exs
config :snakepit,
  timeout_profile: :production,
  
  # Optional: customize margins
  worker_call_margin_ms: 1000,
  pool_reply_margin_ms: 200
```

### Explicit Timeout Configuration

Override profile defaults with explicit values:

```elixir
config :snakepit,
  timeout_profile: :production,
  
  # These override profile-derived values
  pool_request_timeout: 120_000,      # 2 minutes
  pool_streaming_timeout: 600_000,    # 10 minutes
  pool_queue_timeout: 15_000,         # 15 seconds
  grpc_command_timeout: 90_000,       # 90 seconds
  grpc_worker_execute_timeout: 95_000 # 95 seconds
```

### Complete Timeout Options

| Option | Default | Layer | Description |
|--------|---------|-------|-------------|
| `timeout_profile` | `:balanced` | Global | Profile to use for defaults |
| `pool_request_timeout` | Profile-derived | Pool | GenServer.call timeout for execute |
| `pool_streaming_timeout` | Profile-derived | Pool | GenServer.call timeout for streaming |
| `pool_queue_timeout` | Profile-derived | Pool | Max time request waits in queue |
| `checkout_timeout` | Profile-derived | Pool | Worker checkout for streaming |
| `pool_startup_timeout` | 10,000ms | Pool | Worker startup timeout |
| `pool_await_ready_timeout` | 15,000ms | Pool | Wait for pool initialization |
| `grpc_worker_execute_timeout` | Profile-derived | Worker | GenServer.call to GRPCWorker |
| `grpc_worker_stream_timeout` | 300,000ms | Worker | Streaming GenServer.call |
| `grpc_worker_health_check_timeout_ms` | 5,000ms | Worker | Periodic health-check gRPC timeout |
| `grpc_command_timeout` | Profile-derived | Adapter | gRPC call timeout |
| `grpc_batch_inference_timeout` | 300,000ms | Adapter | Batch inference operations |
| `grpc_large_dataset_timeout` | 600,000ms | Adapter | Large dataset processing |
| `grpc_server_ready_timeout` | 30,000ms | Worker | Python server readiness |
| `worker_ready_timeout` | 30,000ms | Worker | Worker ready notification |
| `graceful_shutdown_timeout_ms` | 6,000ms | Worker | Python process shutdown |
| `worker_call_margin_ms` | 1,000ms | Margin | Worker GenServer.call overhead |
| `pool_reply_margin_ms` | 200ms | Margin | Pool reply overhead |

### Per-Call Timeout Override

Override timeouts for individual calls:

```elixir
# Use default from profile
Snakepit.execute("fast_command", %{})

# Override for slow operation
Snakepit.execute("slow_inference", %{model: "large"}, timeout: 300_000)

# Streaming with custom timeout
Snakepit.execute_stream("generate", %{}, callback, timeout: 600_000)
```

---

## Common Scenarios

### Scenario 1: LLM API Calls (60+ seconds)

**Problem**: Default timeouts are too short for LLM inference.

**Solution**: Use `:ml_inference` profile or explicit config:

```elixir
# Option A: Profile-based
config :snakepit, timeout_profile: :ml_inference

# Option B: Explicit timeouts
config :snakepit,
  pool_request_timeout: 300_000,
  grpc_command_timeout: 280_000,
  grpc_worker_execute_timeout: 290_000
```

**Per-call override**:
```elixir
Snakepit.execute("llm_generate", %{prompt: prompt}, timeout: 120_000)
```

### Scenario 2: Fast API with Strict SLAs

**Problem**: Need fast failure for user-facing requests.

**Solution**: Use `:production_strict` profile:

```elixir
config :snakepit, timeout_profile: :production_strict
```

This gives you:
- 60-second default timeout
- 5-second queue timeout (fail fast if pool is saturated)
- Quick feedback to users

### Scenario 3: Batch Processing Jobs

**Problem**: Jobs run for hours, need infinite streaming timeout.

**Solution**: Use `:batch` profile:

```elixir
config :snakepit, timeout_profile: :batch
```

This gives you:
- 60-minute default timeout
- Infinite streaming timeout
- 5-minute queue tolerance

### Scenario 4: Mixed Workloads

**Problem**: Same pool handles fast and slow operations.

**Solution**: Use `:balanced` profile with per-call overrides:

```elixir
config :snakepit, timeout_profile: :balanced

# Fast operations use default
Snakepit.execute("lookup", %{id: id})

# Slow operations override
Snakepit.execute("batch_process", %{data: data}, timeout: 600_000)
```

### Scenario 5: Pool Initialization Takes Too Long

**Problem**: Starting 50+ workers with heavy model loading.

**Solution**: Increase startup timeouts:

```elixir
config :snakepit,
  pool_startup_timeout: 120_000,       # 2 min per worker
  pool_await_ready_timeout: 600_000,   # 10 min total
  grpc_server_ready_timeout: 120_000   # 2 min for Python ready
```

### Scenario 6: Workers Killed During Shutdown

**Problem**: Python cleanup takes longer than 6 seconds.

**Solution**: Increase graceful shutdown timeout:

```elixir
config :snakepit,
  graceful_shutdown_timeout_ms: 15_000  # 15 seconds
```

**Note**: This must be >= Python's shutdown envelope: `server.stop(2s) + wait_for_termination(3s) = 5s`.

---

## Debugging Timeout Issues

### Enable Debug Logging

```elixir
config :snakepit,
  log_level: :debug,
  log_categories: %{
    pool: :debug,
    grpc: :debug,
    worker: :debug
  }
```

### Identify Which Timeout Fired

| Log Pattern | Timeout Type |
|-------------|--------------|
| `** (exit) {:timeout, {GenServer, :call, ...}` | GenServer.call timeout |
| `gRPC error: %GRPC.RPCError{status: 4...}` | gRPC DEADLINE_EXCEEDED |
| `Request timed out after Xms` | Pool queue timeout |
| `Timeout waiting for Python gRPC server` | Server ready timeout |
| `Pool execute timed out` | Pool-level structured timeout |

### Use Telemetry

```elixir
:telemetry.attach("timeout-debug", [:snakepit, :request, :executed], 
  fn _name, measurements, metadata, _config ->
    if measurements[:duration_us] > 30_000_000 do  # > 30s
      Logger.warning("Slow request: #{metadata.command} took #{measurements[:duration_us] / 1_000}ms")
    end
  end, nil)
```

### Check Pool Stats

```elixir
iex> Snakepit.get_stats()
%{
  requests: 15432,
  queued: 5,           # Requests waiting in queue
  queue_timeouts: 12,  # Queue timeout count
  pool_saturated: 3,   # Times pool was at capacity
  ...
}
```

High `queue_timeouts` indicates you need either:
- More workers (`pool_size`)
- Higher `pool_queue_timeout`
- Faster Python operations

### Verify Timeout Derivation

```elixir
iex> alias Snakepit.Defaults

# Check current profile
iex> Defaults.timeout_profile()
:balanced

# Check derived values
iex> Defaults.default_timeout()
300_000

iex> Defaults.rpc_timeout(60_000)
58_800  # 60_000 - 1000 - 200
```

---

## Migration Guide

### Legacy Configuration (Pre-Unified Timeouts)

The timeout architecture is **fully backward compatible**. Existing configurations continue to work:

```elixir
# This still works in current releases
config :snakepit,
  pool_request_timeout: 60_000,
  grpc_command_timeout: 30_000
```

**Behavior changes**:
- When explicit timeouts are set, they take precedence over profile-derived values
- When not set, values now derive from the active profile (default: `:balanced`)
- Default values are similar to previous versions for `:balanced` profile

### Recommended Migration Path

1. **Test with defaults**: Remove explicit timeout config, use profile defaults
2. **Select appropriate profile**: Choose based on workload type
3. **Fine-tune if needed**: Override specific values that don't fit

```elixir
# Before (legacy timeouts)
config :snakepit,
  pool_request_timeout: 300_000,
  pool_streaming_timeout: 900_000,
  pool_queue_timeout: 10_000,
  grpc_command_timeout: 280_000

# After (unified timeouts) - equivalent behavior
config :snakepit, timeout_profile: :balanced
```

### Breaking Changes

None. All existing configuration keys are honored and take precedence over profile-derived values.

---

## API Reference

### Snakepit.Defaults Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `timeout_profiles/0` | `map()` | All available timeout profiles |
| `timeout_profile/0` | `atom()` | Currently configured profile |
| `default_timeout/0` | `timeout()` | Profile's default timeout |
| `stream_timeout/0` | `timeout()` | Profile's streaming timeout |
| `queue_timeout/0` | `timeout()` | Profile's queue timeout |
| `rpc_timeout/1` | `timeout()` | Derive RPC timeout from total budget |
| `worker_call_margin_ms/0` | `integer()` | Worker GenServer.call margin |
| `pool_reply_margin_ms/0` | `integer()` | Pool reply margin |

### Snakepit.Pool Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `get_default_timeout_for_call/3` | `timeout()` | Get timeout for call type |
| `derive_rpc_timeout_from_opts/2` | `timeout()` | Derive RPC timeout from opts with deadline |
| `effective_queue_timeout_ms/2` | `integer()` | Queue timeout respecting deadline |

---

## Related Guides

- [Configuration Guide](configuration.md) - General configuration options
- [Worker Profiles](worker-profiles.md) - Process vs Thread profiles
- [Production Guide](production.md) - Deployment best practices
