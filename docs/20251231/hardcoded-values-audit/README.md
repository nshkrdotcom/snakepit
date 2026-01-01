# Snakepit Hardcoded Values Audit

**Date:** 2025-12-31
**Status:** Audit Complete
**Total Hardcoded Values Found:** 68

## Executive Summary

This audit identified **68 hardcoded values** across the snakepit codebase that should be configurable. The most critical issues are:

1. **30-second default command timeout** - Breaks LLM/long-running operations
2. **Pool sizing defaults** - May not suit all deployment environments
3. **Retry/backoff policies** - Need tuning for different failure scenarios

## Critical Issues

### 1. Default Command Timeout (CRITICAL)

**File:** `lib/snakepit/pool/pool.ex:2243`
**Current:** `30_000` ms
**Impact:** LLM calls, ML inference, and other long-running operations timeout prematurely.

```elixir
# CURRENT (BROKEN)
defp get_command_timeout(command, args, opts) do
  case opts[:timeout] do
    nil ->
      case get_adapter_timeout(command, args) do
        nil -> 30_000  # <-- THIS IS THE PROBLEM
        ...
```

**Recommended Fix:** Change default to `:infinity` or `600_000` (10 min)

### 2. Hardcoded Timeouts Summary

| Location | Value | Controls |
|----------|-------|----------|
| `pool.ex:86` | 60_000 | Pool request timeout |
| `pool.ex:96` | 300_000 | Streaming timeout |
| `pool.ex:2243` | 30_000 | Default command timeout |
| `grpc_worker.ex:122` | 30_000 | Worker execute timeout |
| `grpc_python.ex:250` | 30_000 | gRPC command timeout |
| `executor.ex:136` | 30_000 | Batch operation timeout |

## Recommended Configuration Structure

```elixir
config :snakepit,
  # Timeouts (use :infinity for no timeout)
  timeouts: [
    default_command: :infinity,      # was 30_000
    pool_request: 300_000,           # was 60_000
    pool_streaming: 600_000,         # was 300_000
    pool_startup: 30_000,            # was 10_000
    pool_queue: 30_000,              # was 5_000
    heartbeat_response: 30_000,      # was 10_000
    graceful_shutdown: 10_000,       # was 6_000
  ],

  # Intervals
  intervals: [
    heartbeat_ping: 5_000,           # was 2_000
    health_check: 60_000,            # was 30_000
    session_cleanup: 120_000,        # was 60_000
    worker_lifecycle: 120_000,       # was 60_000
  ],

  # Pool settings
  pool: [
    max_queue_size: 10_000,          # was 1_000
    max_workers_cap: 500,            # was 150
  ],

  # Retry policies
  retry: [
    max_attempts: 5,                 # was 3
    max_backoff_ms: 60_000,          # was 30_000
  ]
```

## Files to Modify

See [implementation-plan.md](implementation-plan.md) for detailed changes.

## Category Breakdown

| Category | Count | Priority |
|----------|-------|----------|
| Timeouts | 23 | CRITICAL |
| Pool/Worker Sizes | 7 | HIGH |
| Retry/Backoff | 8 | MEDIUM |
| Intervals | 10 | MEDIUM |
| Buffer/Queue Sizes | 5 | LOW |
| Other | 15 | LOW |
