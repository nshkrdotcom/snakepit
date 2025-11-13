# Snakepit Slow Test Investigation — 2025-11-13

This document captures the current long-running tests surfaced by `mix test --slowest` instrumentation. The goal is to explain **why** each case is expensive, whether the cost is essential for coverage, and which suites should be tagged for default exclusion (e.g., `@tag :slow`, `@tag :skip_ci`, or a forthcoming `:integration` marker).

## Snapshot of Slowest Tests

| Rank | Test (Module :: description) | File:Line | Duration (ms) | Primary Cause |
| --- | --- | --- | --- | --- |
| 1 | `Snakepit.Pool.WorkerLifecycleTest :: ApplicationCleanup does NOT run during normal operation` | `test/snakepit/pool/worker_lifecycle_test.exs:167` | 6,352 | Shelling out to `pgrep` and sampling OS process counts over ~2s to prove cleanup inactivity |
| 2 | `Snakepit.Config.StartupFailFastTest :: env doctor failure aborts startup` | `test/unit/config/startup_fail_fast_test.exs:142` | 4,940 | Full application restart + doctor instrumentation + waiting for supervisor failure propagation |
| 3 | `Snakepit.Config.StartupFailFastTest :: application start fails when adapter executable is missing and registry stays empty` | `test/unit/config/startup_fail_fast_test.exs:38` | 4,912 | Cold stop/start of the OTP app plus DETS/registry checks after a forced init failure |
| 4 | `Snakepit.Config.StartupFailFastTest :: gRPC port binding conflict aborts startup without leaking workers` | `test/unit/config/startup_fail_fast_test.exs:113` | 4,809 | Binds a real TCP port, restarts the entire supervision tree, and waits for cleanup before returning |
| 5 | `Snakepit.Config.StartupFailFastTest :: env doctor is invoked before pools boot` | `test/unit/config/startup_fail_fast_test.exs:167` | 4,643 | Exercises fake doctor callbacks plus full application restart before verifying sequencing |
| 6 | `Snakepit.Pool.WorkerSupervisorTest :: restart_worker/1 probes requested port when worker bound to a fixed port` | `test/unit/pool/worker_supervisor_test.exs:115` | 3,830 | Forces worker restart, blocks TCP port via :gen_tcp + assert_eventually loops, waits for cleanup timeout |
| 7 | `Snakepit.Pool.QueueSaturationRuntimeTest :: requests that time out in queue never execute and queue saturations emit stats` | `test/unit/pool/pool_queue_management_test.exs:212` | 2,720 | Launches 10 concurrent executions with 500 ms adapter delays, collects telemetry, and waits for queue drains |
| 8 | `Snakepit.Pool.ApplicationCleanupTest :: ApplicationCleanup does NOT kill processes from current BEAM run` | `test/snakepit/pool/application_cleanup_test.exs:37` | 2,213 | Runs against live workers, shells to `pgrep` 20×, samples over 2 s to verify stability |
| 9 | `Snakepit.Bridge.PythonSessionContextTest :: session lifecycle with Python session expires after TTL` | `test/snakepit/bridge/python_session_context_test.exs:63` | 1,212 | Creates short-TTL sessions and repeatedly triggers cleanup until expiry is observed |
| 10 | `Snakepit.GRPC.HeartbeatIntegrationTest :: does not start heartbeat monitor when disabled` | `test/snakepit/grpc/heartbeat_integration_test.exs:74` | 1,071 | Spins up a real GRPCWorker, waits for heartbeat instrumentation, and `refute_receive`s for 1s |

## Detailed Findings & Mitigations

### 1. WorkerLifecycle “ApplicationCleanup does NOT run during normal operation”
- **What it does:** Starts the full pool, waits until at least two Python workers are running, and samples `pgrep -f "grpc_server.py"` output ten times (line 167 onward).
- **Why it is slow:**
  - `assert_eventually` polls for up to 10 s for worker readiness.
  - Each sample does a blocking `System.cmd("pgrep", …)` call, crossing the BEAM ↔︎ OS boundary.
  - The test then loops for ~2 s (10 × 200 ms receive timeouts) to prove the process count stays constant.
- **Recommendation:** Keep it as a full integration guard but permanently tag `@moduletag :skip_ci` (already present) and consider moving to an “extended integration” mix task. For faster smoke tests, write a unit-level regression that asserts `ApplicationCleanup` ignores the current `beam_run_id` without touching OS processes.

### 2–5. StartupFailFastTest variants
These four tests share the same structure: they fully stop the Snakepit OTP application, mutate application env, restart the supervision tree, and assert failure behavior (missing adapter, env doctor failure, gRPC port conflict, doctor sequencing).

- **Why they are slow:**
  - `Application.stop(:snakepit)` followed by `Application.ensure_all_started/1` forces global teardown/startup, which cascades to pool supervisors, gRPC supervisors, DETS-backed registries, etc.
  - The env doctor scenarios deliberately block until callbacks fire and responses propagate through `await_ready_result/1`, introducing up to 5 s of waits.
  - The port-conflict test binds a real TCP socket via `:gen_tcp.listen/2`, then waits for the gRPC supervisor to crash gracefully before closing the socket.
- **Mitigation ideas:**
  1. Introduce a `@moduletag :slow` (or reuse `:skip_ci`) so these only run in nightly / `mix test --include slow` contexts.
  2. Where possible, swap full application restarts for supervisor injections (e.g., start a throwaway supervisor with the failing child). That would keep coverage but reduce 4–5 s of restart overhead.
  3. Cache env snapshots at the module level to avoid repeated `Application.put_env` churn per test—currently every test does `capture_log(fn -> Application.stop ... end)`, which duplicates work.

### 6. WorkerSupervisor fixed-port probe regression (test/unit/pool/worker_supervisor_test.exs:115)
- **Scenario:** Ensures `WorkerSupervisor.restart_worker/1` re-probes requested ports when a worker is pinned to a fixed port.
- **Sources of latency:**
  - The test waits for a real worker to boot (`Snakepit.Pool.await_ready`), which can take ~1 s depending on environment.
  - It restarts the worker and intentionally blocks the requested TCP port via `bind_port!`, forcing `restart_worker` to timeout after 5 s before cleaning up.
  - `assert_eventually` loops ensure the registry is updated, adding more delay.
- **Potential improvements:** Allow the adapter stub to simulate “port already bound” without needing actual `:gen_tcp` sockets, cutting most of the 3.8 s. Regardless, tag the module as `:slow` or split the fixed-port test into an integration-only suite.

### 7. Queue saturation runtime test (test/unit/pool/pool_queue_management_test.exs:212)
- **Scenario:** Launches 10 concurrent `Snakepit.execute/2` calls against `QueueProbeAdapter`, which delays each invocation by 500 ms to force queue saturation.
- **Latency drivers:**
  - `Task.async_stream` with `timeout: 15_000` and forced adapter delays intentionally holds the BEAM busy for ~2.5 s even when everything succeeds.
  - After the tasks complete, the test queries ETS-backed stats and the Agent tracking executed IDs, adding synchronization overhead.
- **Ideas:** Parameterize the adapter delay so the fast test path can use 50–100 ms (still enough to hit saturation) while a longer delay is reserved for `:slow` runs.

### 8. ApplicationCleanup integration test (test/snakepit/pool/application_cleanup_test.exs:37)
- **Nature:** Similar to the WorkerLifecycle test, but focused on ensuring `ApplicationCleanup` never kills processes from the current run.
- **Why it lingers:**
  - Setup ensures the entire application is running and waits up to 30 s for readiness (line 22), though typically shorter.
  - The test samples OS process counts 20 times at 100 ms intervals (`monitor_process_stability/3`), again shelling out to `pgrep`.
- **Action:** Already tagged `@moduletag :skip_ci`; maintain that and consider gating it behind `mix test --include cleanup`. Provide a pure Elixir unit test for the run-id filter to cover most regressions quickly.

### 9. PythonSessionContext TTL test (test/snakepit/bridge/python_session_context_test.exs:63)
- **Description:** Creates a session with a 1 s TTL, then repeatedly calls `SessionStore.cleanup_expired_sessions/0` until the session disappears.
- **Cost:** Even with manual cleanup triggers, the test effectively waits a full second for TTL expiry, plus `assert_eventually` overhead (5 s timeout with 100 ms polling). This is acceptable for correctness but still >1 s.
- **Recommendation:** Tag the TTL example as `@tag :slow` and add a faster unit test that mocks `SessionStore` timestamps so TTL math can be validated without wall-clock waits.

### 10. HeartbeatIntegration “does not start heartbeat monitor when disabled” (test/snakepit/grpc/heartbeat_integration_test.exs:74)
- **Behavior:** Spawns a real `Snakepit.GRPCWorker` hooked to the `MockGRPCAdapter`, then `refute_receive`s heartbeat monitor events for 1 s.
- **Why it shows up:** The `refute_receive ... , 1_000` effectively sleeps for a full second when the monitor is correctly disabled, dominating runtime.
- **Next steps:** Either:
  - Replace the `refute_receive` with a pollable flag inside the adapter (so the test can finish as soon as it proves “no monitor started”), or
  - Tag this test as `@tag :slow` and rely on the faster `HeartbeatMonitor` unit tests for day-to-day runs.

## Tagging & Default-Exclusion Candidates

| Module | Current Tags | Proposed Default Behavior |
| --- | --- | --- |
| `Snakepit.Pool.WorkerLifecycleTest` | `@tag :skip_ci` (per-test) | Keep `:skip_ci`; optionally add `@moduletag :slow` so devs can `mix test --exclude slow` locally |
| `Snakepit.Pool.ApplicationCleanupTest` | `@moduletag :skip_ci` | Keep as is; ensure CI matrix has an opt-in job for `--include skip_ci` or rename to `:cleanup_integration` |
| `Snakepit.Config.StartupFailFastTest` | none | Add `@moduletag :slow` or individual `@tag :slow` for restart-heavy cases; default-exclude from rapid unit runs |
| `Snakepit.Pool.WorkerSupervisorTest` | none | Tag the fixed-port probe test as `:slow` or split into a dedicated `*_integration_test.exs` file |
| `Snakepit.Pool.QueueSaturationRuntimeTest` | none | Tag module as `:slow`; also expose adapter delay via config to shorten default runs |
| `Snakepit.Bridge.PythonSessionContextTest` | none | Tag the TTL test as `:slow` (others can remain fast) |
| `Snakepit.GRPC.HeartbeatIntegrationTest` | none | Tag the “disabled monitor” case as `:slow` or refactor to remove the 1 s `refute_receive` |

Adopting a consistent tag (e.g., `@tag :slow` or `@moduletag :integration`) allows `mix test` to stay fast while CI/nightly jobs run `mix test --include slow`. Existing `:skip_ci` tags already keep the worst offenders out of mainline runs, but a first-class `:slow` marker makes local exclusion easier.

## Why So Many Slow Tests?

Most of these suites model **real lifecycle failures** (pool teardown, env doctor aborts, OS process cleanup). They lean on:

1. **Full supervision-tree restarts** — stopping/starting the application is expensive but necessary to prove fail-fast behavior.
2. **External process inspection** — calling `pgrep`, binding TCP ports, or waiting for DETS updates incurs OS-level latency.
3. **Intentional timeouts** — queue saturation, TTL expiry, and heartbeat suppression rely on real timers to guarantee behavior.

Those factors mean the tests genuinely need more time than unit tests. Rather than forcing artificial speed-ups (and risking coverage gaps), we should classify them clearly so developers and CI can choose when to run them.

## Suggested Next Steps

1. **Introduce a unified `:slow` tag** across the suites above and update `mix test` defaults (`--exclude slow`). Document this in `README_TESTING.md`.
2. **Add faster unit tests** for the same invariants (e.g., ApplicationCleanup run-id filtering, WorkerSupervisor port probing) so contributors get rapid feedback without running the full integration cases.
3. **Parameterize wait intervals** (adapter delays, TTLs, `refute_receive` durations) via module attributes so we can dial them down when running in “fast” mode.
4. **Establish an opt-in CI job** (nightly or pre-release) that runs `mix test --include slow --include skip_ci` to preserve coverage without slowing every PR.

Doing the above keeps the comprehensive integration coverage intact while ensuring day-to-day developer loops stay quick.
