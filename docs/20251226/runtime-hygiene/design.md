# Snakepit Runtime Hygiene and Process Lifecycle

Date: 2025-12-26
Status: Draft
Owner: Snakepit core

## Summary

Snakepit spawns external Python gRPC workers and relies on BEAM shutdown to
clean them up. In short-lived runs (ex: `mix run`), the BEAM can exit before
all OS processes terminate, leaving orphans that are only cleaned on next boot.
This document defines a deterministic cleanup barrier, process-group handling,
and quiet-by-default logging so library users are not flooded with noise.

## Background

Current architecture:

- Python workers are OS processes launched by Snakepit and tracked by
  `ProcessRegistry` using `beam_run_id` + `beam_os_pid`.
- Worker termination attempts to kill the Python PID with escalation.
- Orphan cleanup runs on next boot and periodically in `ProcessRegistry`.
- Logs can be noisy for library consumers (worker readiness, telemetry, and
  Python stdout).

## Goals

- Deterministic cleanup of Python workers on normal shutdown.
- Quiet-by-default logging for library usage without losing error visibility.
- Safe, run_id-scoped cleanup (never kill unrelated processes).
- Cross-platform fallback behavior with clear feature flags.

## Non-goals

- Redesigning the runtime protocol.
- Managing external process supervisors (systemd, launchd).
- Providing process management for user-launched Python outside Snakepit.

## Proposed Design

### 1) Shutdown Cleanup Barrier

Add a synchronous cleanup phase in `Snakepit.Application.stop/1` that blocks
until all known worker PIDs for the current run are gone or a timeout is
reached.

Algorithm:

1. Collect active worker PIDs for current `beam_run_id` from `ProcessRegistry`.
2. Send SIGTERM to each PID and wait up to `cleanup_on_stop_timeout_ms`.
3. If any PID remains, send SIGKILL.
4. Re-check and log if any survive (warn, do not retry forever).

Pseudocode:

```
Application.stop/1
  if cleanup_on_stop:
    pids = ProcessRegistry.pids_for_run(current_run_id)
    kill_with_escalation(pids, timeout_ms)
    wait_until_dead(pids, poll_interval_ms, timeout_ms)
```

### 2) Process Group Termination

OS PIDs can spawn subprocesses. To avoid stragglers, optionally launch Python
in a new process group and kill the group:

- When spawning the worker, create a new process group (`setsid` on Linux).
- Record the process group ID (pgid) in registry metadata.
- On termination, prefer killing the pgid with SIGTERM -> wait -> SIGKILL.

Fallback:

- If process groups are not supported, fall back to killing only the PID.
- Gate with `process_group_kill` config flag.

### 3) Emergency Cleanup Always Available

`Snakepit.Pool.ApplicationCleanup` currently runs only when pooling is enabled.
Change it to always start, but remain lightweight when pooling is disabled.
This ensures emergency cleanup runs even in minimal library usage.

### 4) Cleanup Timing and Backoff

Standardize cleanup timing knobs:

- `cleanup_on_stop_timeout_ms` (default: 3000)
- `cleanup_poll_interval_ms` (default: 50)
- `cleanup_retry_interval_ms` and `cleanup_max_retries` for pool supervisor

These values should be configurable and documented for CI vs prod.

### 5) Manual Cleanup API

Expose `Snakepit.cleanup/0` so host applications can explicitly run cleanup on
exit when they control lifecycle (ex: library embedding, scripts).

## Logging Policy (Quiet by Default)

Library consumers should not see verbose logs unless they opt in.

Defaults:

- `log_level: :warning`
- `grpc_log_level: :error` (set per application level)
- `log_python_output: false` (only emit Python stdout on error/timeout)
- `library_mode: true` (enforces quiet defaults)

Host apps can override via config.

## Configuration

Proposed config keys and defaults:

```
config :snakepit,
  library_mode: true,
  log_level: :warning,
  grpc_log_level: :error,
  log_python_output: false,
  cleanup_on_stop: true,
  cleanup_on_stop_timeout_ms: 3000,
  cleanup_poll_interval_ms: 50,
  process_group_kill: true
```

## Observability

Telemetry events for cleanup:

- `[:snakepit, :cleanup, :start]`
- `[:snakepit, :cleanup, :success]`
- `[:snakepit, :cleanup, :timeout]`

Logs should be warning-only for timeouts or any kills.

## Failure Modes

- PID reuse: guard by verifying command line includes the expected run_id.
- Process group kill risk: only kill groups created by Snakepit.
- Short-lived runs: cleanup barrier prevents next-run orphan warnings.

## Testing Plan

- Integration test: start workers, run a call, exit quickly, assert no orphans.
- Process group test: worker spawns a child; ensure group kill removes both.
- Manual cleanup test: call `Snakepit.cleanup/0` and assert registry clean.
- Logging test: default config emits no info-level noise.

## Rollout

1. Add config flags and cleanup barrier behind defaults.
2. Add process group handling with feature flag.
3. Add manual cleanup API + telemetry.
4. Update docs and examples to mention quiet defaults.

## Open Questions

- Should `cleanup_on_stop_timeout_ms` differ by Mix env?
- How to handle process group kill on Windows?
- Should `Snakepit.cleanup/0` run automatically in atexit hooks for scripts?
