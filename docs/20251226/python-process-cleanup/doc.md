# Snakepit Python Process Cleanup Reliability

Date: 2025-12-26  
Status: Proposal  
Owner: Snakepit core

## Summary

Snakepit runs external Python gRPC servers and tracks their OS PIDs. In fast
shutdown paths (ex: `mix run` exits immediately after work completes), the BEAM
can terminate before all OS processes exit. The next boot then detects and kills
orphaned workers. This proposal makes cleanup deterministic at shutdown, reduces
orphan cleanup on the next run, and exposes a manual cleanup hook for embedding
libraries.

## Context

Relevant modules and behavior:

- `lib/snakepit/grpc_worker.ex`
  - Spawns Python gRPC server, traps exits, and calls
    `Snakepit.ProcessKiller.kill_with_escalation/2` on terminate.
- `lib/snakepit/pool/worker_starter.ex` + `lib/snakepit/pool/worker_supervisor.ex`
  - Terminates workers and waits for resources to be released.
- `lib/snakepit/pool/process_registry.ex`
  - Stores `worker_id`, `process_pid`, `beam_run_id`, `beam_os_pid` in DETS.
  - Performs orphan cleanup at startup and periodically.
- `lib/snakepit/pool/application_cleanup.ex`
  - Emergency cleanup in supervision tree shutdown.

Observed symptom: consecutive runs emit warnings about orphaned Python gRPC
processes from the previous BEAM run. Cleanup happens on the next boot rather
than in the shutdown that created the orphans.

## Goals

- Ensure shutdown attempts to clean external Python processes synchronously.
- Reduce or eliminate orphan cleanup on the next boot for normal exits.
- Provide a manual cleanup API for embedding libraries (SnakeBridge).
- Preserve safety (do not kill unrelated processes).

## Non-goals

- No changes to core runtime protocol or adapter API.
- No changes to Python-side code unless needed for process group handling.
- No platform-specific daemon management (systemd, launchd, etc).

## Problem Details

Fast VM exit can interrupt orderly shutdown:

- Workers are terminated, but OS processes may still be exiting.
- The VM stops before cleanup completes.
- ProcessRegistry detects stale PIDs on next boot and kills them.

This is correct but noisy and can confuse users who expect each run to clean up
immediately.

## Proposed Changes

### 1) Synchronous Cleanup on Application Stop

Add a shutdown cleanup phase in `Snakepit.Application.stop/1`:

- Call a cleanup function that blocks until all known worker PIDs are gone or a
  timeout is reached.
- Use `ProcessRegistry.manual_orphan_cleanup/0` and/or a new function that
  explicitly kills by current run_id (safer than broad process scans).
- Configuration:
  - `:cleanup_on_stop` (default: true)
  - `:cleanup_on_stop_timeout_ms` (default: 2000-5000)

Ordering:

1. Supervisors stop (normal worker termination runs).
2. Application stop runs cleanup to catch any stragglers.

This makes cleanup deterministic even for `mix run` paths that exit quickly.

### 2) Harden GRPCWorker Termination

`GRPCWorker.terminate/2` already calls `ProcessKiller.kill_with_escalation/2`.
Strengthen it by ensuring child processes are not left behind:

- Spawn Python in its own process group (ex: `setsid` or equivalent).
- Kill the process group, not just the parent PID:
  - SIGTERM -> wait -> SIGKILL
- Extend `ProcessKiller` with:
  - `kill_process_group/2`
  - `kill_group_with_escalation/2`

This prevents a Python gRPC server from leaving subprocesses running.

### 3) Run Emergency Cleanup Even When Pooling Disabled

`Snakepit.Pool.ApplicationCleanup` only runs when pooling is enabled.

Proposal:

- Always include ApplicationCleanup as a child, but make it lightweight when
  pooling is disabled.
- It should still run final cleanup on shutdown for any external Python
  processes started outside the pool path.

### 4) Increase Cleanup Wait/Health Checks on Stop

`WorkerSupervisor` waits for resource cleanup with retry/backoff. Provide
configurable parameters and default them to slightly higher values for external
process shutdown:

- `:cleanup_retry_interval_ms` (existing)
- `:cleanup_max_retries` (existing)
- `:cleanup_total_timeout_ms` (new derived or explicit)

This reduces the window where the VM exits before PIDs fully terminate.

### 5) Manual Cleanup Hook for Libraries

Expose a stable, public API for embedding libraries to call at exit:

- `Snakepit.cleanup/0` (new public function)
  - Calls `ProcessRegistry.manual_orphan_cleanup/0`
  - Optionally `ProcessKiller.kill_by_run_id/1`

This allows SnakeBridge or other consumers to ensure a clean shutdown explicitly
when they control the app lifecycle.

## Design Details

### Shutdown Flow

```
Application.stop/1
  -> ProcessRegistry.manual_orphan_cleanup/0
  -> ProcessKiller.kill_by_run_id(current_run_id)
  -> Wait for PIDs to disappear or timeout
```

Wait implementation:

- Poll `ProcessKiller.process_alive?/1` with a short backoff (ex: 50ms).
- Exit early when all PIDs are gone.
- If timeout expires, emit a warning (still safe).

### Process Group Support

To kill child processes reliably:

- Spawn Python via a shell wrapper that calls `setsid` (Linux).
- Capture parent PID and process group ID if possible.
- Use `kill -TERM -pgid` and `kill -KILL -pgid` via `ProcessKiller`.

Safety:

- Only kill process groups created by Snakepit.
- Validate `grpc_server.py` command line includes the current run_id marker.

### Configuration

New keys (defaults shown):

```
config :snakepit,
  cleanup_on_stop: true,
  cleanup_on_stop_timeout_ms: 3000,
  cleanup_poll_interval_ms: 50,
  log_python_output: false,
  library_mode: true
```

Existing keys used:

- `:cleanup_retry_interval`
- `:cleanup_max_retries`
- `:rogue_cleanup` options

### Observability

Emit telemetry:

- `[:snakepit, :cleanup, :start]`
- `[:snakepit, :cleanup, :success]`
- `[:snakepit, :cleanup, :timeout]`

Log at warning only if cleanup times out or kills any processes.

## Testing Strategy

1. Integration test: start a worker, run a call, stop app quickly, then assert
   no orphaned PIDs remain (using a test ProcessKiller stub).
2. Process group kill test: spawn a Python process that forks a child, ensure
   group kill clears both.
3. Manual cleanup test: call `Snakepit.cleanup/0` and verify it removes stale
   registry entries and kills expected PIDs.

## Risks

- PID reuse: already mitigated by verifying command line includes run_id.
- Process group kill could be too aggressive if not scoped correctly.
- Blocking shutdown for too long could slow fast CLI workflows.

## Rollout Plan

1. Add new cleanup API and config defaults.
2. Enable synchronous cleanup in stop/1 behind config flag.
3. Add process group support; keep feature flag until verified in CI.

## Open Questions

- Best default timeout for shutdown cleanup in CLI use?
- Cross-platform support for process group kill (Windows)?
- Should Snakepit expose a Mix task for manual cleanup?
