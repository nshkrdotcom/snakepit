Here’s a prompt you can hand to an agent as-is. It’s written assuming the agent has access to the repo and can edit code, run tests, and spawn OS processes.

---

```text
You are an engineer working on the Snakepit codebase.

Repo layout (important bits):

- Elixir source:
  - lib/snakepit/** (core system, pool, workers, process registry, telemetry, etc.)
- Python bridge:
  - priv/python/** and priv/python/snakepit_bridge/**
- Tests (already present & passing):
  - test/unit/** (unit tests)
  - test/snakepit/** (higher-level integration/unit)
  - test/integration/** (integration)
  - test/performance/** (performance / throughput)
- Examples & load demos:
  - examples/** (standalone scripts, loadtest app, showcase app)

You must **add a suite of “fail-fast experiments”** that deliberately exercise bad conditions and failure modes to prove that Snakepit:
- Fails fast and loudly on misconfiguration or resource problems
- Cleans up external Python processes reliably (no orphans)
- Recovers from worker / bridge failures under load
- Keeps invariants around queueing, session affinity, and streaming

All existing tests and examples already pass; your work must **augment** them, not break them.

## Global constraints

- Use existing tooling:
  - Elixir tests via `mix test`
  - Python tests via the existing Python env (see test/support/python_env.ex, requirements, etc.)
- Prefer pure Elixir/OTP mechanisms over shelling out, **except** where explicitly asked to simulate OS-level failures.
- Keep tests deterministic and fairly quick; if a scenario is inherently heavy, park it under `test/performance` or `examples/snakepit_loadtest`.
- Where possible, validate invariants via public APIs (Snakepit, ProcessRegistry, SessionStore) rather than poking directly at private state.

## High-level tasks

Implement the following new experiments/tests. Each experiment MUST have:

1. A clearly named test module + file (see suggestions below).
2. A short docstring in the test module explaining the scenario.
3. Comments near the assertions explaining the invariant.
4. Where applicable, a small README snippet or doc comment cross-linking to the relevant module(s).

Where I say “use telemetry”, you may rely on `:telemetry.attach/4` and `TelemetryMetrics` helpers already present in the codebase.

---

### Experiment 1: Orphaned Python process stress test (BEAM crash & restart)

**Goal:** Prove that *no* `grpc_server.py` Python processes are left orphaned in realistic crash/restart scenarios, and that DETS cleanup behaves as designed.

**Location:**
- Add an integration test: `test/integration/orphan_cleanup_stress_test.exs`
- Optionally add a small helper script in `examples/snakepit_loadtest/` if needed to drive load between restarts.

**Scenario:**

1. Start Snakepit application fully:
   - Ensure pooling is enabled and using `Snakepit.Adapters.GRPCPython`.
   - Use a moderate pool size (e.g. 8–16 workers) to keep test time reasonable.

2. Generate some load:
   - Use `Snakepit.execute/3` with a simple command (`"ping"`, `"echo"`, `"compute"`) on multiple concurrent tasks for a few seconds.
   - Assert that `Snakepit.Pool.ProcessRegistry.get_stats/0` shows `total_registered > 0` and some `alive_workers`.

3. Simulate BEAM crash & restart **within the test**:
   - Start Snakepit in a supervised manner under the test process (for example, via a temporary supervisor or using a test-only helper; reuse existing `test/support/test_case.ex` if possible).
   - After load, **forcefully stop** the Snakepit application (e.g. `Application.stop(:snakepit)` or terminate the supervisor).
   - DO NOT manually call any cleanup functions; assume a crash-like shutdown.

4. Restart Snakepit application:
   - Call `Application.start(:snakepit)` again.
   - Allow `ProcessRegistry`’s startup cleanup to run.

5. Assertions:
   - Use OS-level checks (via `Snakepit.ProcessKiller.find_python_processes/0` + `get_process_command/1`) to assert there are **no** Python processes whose command line includes `grpc_server.py` and a run-id that does **not** match the current run ID.
   - Assert that `Snakepit.Pool.ProcessRegistry.debug_show_all_entries/0` returns:
     - `entries_info` where any entry with `is_current_run == false` has `process_alive: false`.
   - Assert that `dets_table_size` only includes entries for the current run ID (if any), and that a second restart doesn’t grow DETS unbounded.

**Deliverables:**

- `test/integration/orphan_cleanup_stress_test.exs` containing at least one test that:
  - Starts, crashes, restarts Snakepit,
  - Verifies no stale DETS entries,
  - Verifies no orphaned Python workers.

---

### Experiment 2: Worker crash storms under load

**Goal:** Show that repeatedly killing workers under load doesn’t leak external processes or break the pool; pool recovers and continues serving requests.

**Location:**
- Extend `test/performance/pool_throughput_test.exs` or add `test/performance/worker_crash_storm_test.exs`.

**Scenario:**

1. Start Snakepit with a pool size of e.g. 8 workers.
2. Fire a continuous stream of requests from multiple tasks:
   - Example: `Task.async_stream(1..200, fn _ -> Snakepit.execute("compute", %{a: 1, b: 2}) end, max_concurrency: 16, timeout: 10_000)`

3. While that’s running, in a loop:
   - Enumerate current workers via `Snakepit.Pool.list_workers/0`.
   - Randomly pick one or more worker IDs.
   - Use a **test-only code path** (or `Process.exit(pid, :kill)` via `Pool.Registry.get_worker_pid/1`) to simulate worker crashes.
   - Allow the supervision tree to restart them via `Worker.Starter` + `WorkerSupervisor`.

4. After N cycles (e.g. 20–50 crash events):
   - Stop the load.
   - Assert that:
     - `Snakepit.Pool.get_stats/0` has `errors` within a reasonable bound (some errors ok if you kill mid-request, but the pool should not be dead).
     - All workers have been re-registered (worker count == configured pool size).
   - Use `Snakepit.Pool.ProcessRegistry.get_stats/0` to assert that `dead_workers` == 0 and `active_process_pids` doesn’t grow linearly with crashes.

5. Optionally, re-use `ProcessKiller.process_alive?/1` to verify PIDs of replaced workers are gone.

---

### Experiment 3: Fail-fast on startup misconfiguration

**Goal:** Verify that obvious misconfigurations cause **early, clear failures**, not half-initialized pools or silent no-op.

**Location:**
- Extend `test/unit/config/config_test.exs`
- Add `test/unit/config/startup_fail_fast_test.exs`

**Scenarios (separate tests):**

1. **Missing adapter executable:**
   - Temporarily set `Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)` and override `:python_executable` to a bogus path.
   - Start Snakepit application and assert:
     - It fails to start with a clear error (use `catch_exit/1` or `assert_raise`),
     - No workers are registered in `Pool.Registry`,
     - `ProcessRegistry.dets_table_size` remains 0.

2. **Invalid pool profile:**
   - Configure a pool with `worker_profile: :unknown`.
   - Call `Snakepit.Config.get_pool_configs/0` and assert it returns an error tuple `{:error, {:invalid_profile, :unknown, _}}`.
   - Ensure that `Snakepit.Application.start/2` (or a test-local start) doesn’t silently fall back; it should fail to start.

3. **Port binding conflict:**
   - Simulate the gRPC server failing to bind (e.g., start a temporary server on the same port that Snakepit wants, then start Snakepit).
   - Assert that startup fails with a descriptive message and does not leak any workers.

---

### Experiment 4: Heartbeat failure & independent/dependent behavior

**Goal:** Confirm heartbeat behavior under real failure conditions:
- Dependent workers should die when heartbeat can’t reach Elixir.
- Independent workers should **not** die, but should emit telemetry.

**Location:**
- Extend `test/snakepit/grpc/heartbeat_end_to_end_test.exs` or add `test/snakepit/grpc/heartbeat_failfast_test.exs`.

**Scenarios:**

1. **Dependent worker:**
   - Configure heartbeat with `dependent: true` (default).
   - Start one worker, attach telemetry to `[:snakepit, :heartbeat, :monitor_failure]` and `[:snakepit, :heartbeat, :heartbeat_timeout]`.
   - Simulate heartbeat failure by:
     - Mocking the ping path to always return error OR
     - Dropping the Elixir side by stopping the bridge server temporarily.
   - Assert:
     - At least one `:heartbeat_timeout` and `:monitor_failure` event is emitted.
     - The worker process receives a shutdown and is no longer in `Pool.Registry`.
     - The Python process is killed via `ProcessKiller` (no `process_alive?`).

2. **Independent worker (dependent: false):**
   - Configure heartbeat via `SNAKEPIT_HEARTBEAT_CONFIG` (env) or per-worker config with `dependent: false`.
   - Simulate heartbeat failure again.
   - Assert:
     - Heartbeat monitor **does not** kill the worker.
     - Instead, monitor logs/telemetry show repeated failures, but the worker still serves `Snakepit.execute/3` calls.

---

### Experiment 5: Streaming cancellation & worker checkin

**Goal:** Ensure that when a client cancels a streaming call (drops the connection or times out), the worker is checked in and not left “busy” forever; no chunks are delivered after cancellation.

**Location:**
- Extend `test/snakepit/streaming_regression_test.exs`.

**Scenario:**

1. Start Snakepit with gRPC adapter & streaming enabled.
2. Kick off a streaming call via `Snakepit.execute_stream/4` using a long-running streaming command from the showcase adapter (e.g. `streaming_ops.infinite_stream` or `stream_progress_demo` style command).
3. In the callback, after receiving a few chunks:
   - Simulate client cancellation:
     - E.g., raise an exception from inside the callback, or have the callback return `:halt` to stop consumption.
4. After the stream ends:
   - Assert that the worker ID used for the stream is back in the pool’s `available` set:
     - Use `Snakepit.Pool.get_stats/0` or a test helper that introspects the pool state.
   - Assert via telemetry (`[:snakepit, :request, :executed]`) that the request is marked as completed (or error) and not stuck.
   - Ensure no extra chunks are processed after `:halt`.

---

### Experiment 6: Queue saturation and timeouts correctness

**Goal:** Under deliberate saturation, ensure:
- Requests that time out in the queue are *never executed*.
- The queue drains correctly and `cancelled_requests` doesn’t grow unbounded.
- `pool_saturated` metric increments when it should.

**Location:**
- Extend `test/unit/pool/pool_queue_management_test.exs` and/or `test/unit/pool/pool_client_cancellation_test.exs`.

**Scenario:**

1. Configure a small pool (e.g. 1 worker) and a very small `max_queue_size` (e.g. 5) and short `queue_timeout` (e.g. 100ms).
2. Create a command handled by the Python side that:
   - Sleeps for a fixed time longer than `queue_timeout` (e.g. 500ms), so requests back up.

3. Launch more concurrent calls than `max_queue_size`, e.g. 20 calls:
   - Some should execute immediately (first 1), some should be queued, others should get rejected with `{:error, :pool_saturated}`.

4. Assertions:
   - Confirm that:
     - A number of callers receive `{:error, :queue_timeout}`.
     - Some receive `{:error, :pool_saturated}`.
   - Use a side effect (e.g. increment a counter in the external process) to verify that requests which timed out **never** actually executed.
   - Check internal pool stats:
     - `stats.queue_timeouts` matches the number of timed-out requests.
     - `stats.pool_saturated` > 0.
   - Assert that after some idle time, `cancelled_requests` map is pruned down (not unbounded).

---

### Experiment 7: Multi-pool interaction under failure

**Goal:** When one pool is misconfigured or failing, other pools should continue to work normally; failures should be isolated by pool.

**Location:**
- Extend `test/snakepit/multi_pool_execution_test.exs`.

**Scenario:**

1. Configure two pools:
   - `:default` – valid configuration, working adapter.
   - `:broken_pool` – e.g. invalid adapter executable or invalid worker profile.

2. Start Snakepit with both pools configured.
3. Assert:
   - Commands dispatched to `:default` succeed as normal.
   - Commands dispatched to `:broken_pool` fail fast with descriptive errors (`{:error, {:pool_not_initialized, ...}}` or similar).
   - The failure to initialize `:broken_pool` does **not** prevent `:default` from starting.

---

### Experiment 8: Rogue `grpc_server.py` processes detection boundaries

**Goal:** Validate `ProcessKiller.kill_by_run_id/1` and rogue cleanup logic respects run IDs and doesn’t accidentally kill non-Snakepit processes that happen to have similar names.

**Location:**
- Extend `test/snakepit/process_killer_test.exs`.

**Scenario:**

1. Spawn a fake “rogue” Python process (could be a tiny script) that:
   - Has `python` in its command line
   - **Does not** include `grpc_server.py` or any `--snakepit-run-id`/`--run-id` flag.

2. Spawn another fake process whose command line looks similar to a Snakepit worker but uses a **different** run ID.

3. Call `Snakepit.ProcessKiller.kill_by_run_id(current_run_id)`.

4. Assertions:
   - “Rogue” process without run-id is **not** killed.
   - Process with mismatched run-id is killed.
   - Confirm via `process_alive?/1` and by inspecting commands.

(*Note*: You can simulate commands via wrappers or by calling a small Python script that prints argv and sleeps.)

---

### Implementation checklist

For each of the above experiments:

- [ ] New test file created in the specified directory.
- [ ] Tests compile and pass locally via `mix test`.
- [ ] No flakiness under repeated runs (e.g. `mix test --seed 0`, multiple times).
- [ ] No tests leave Python processes alive after completion (verify with `ProcessKiller.find_python_processes/0` in teardown or CI helper).
- [ ] Any new helper code added under `test/support` is clearly documented and not used in production code.

When done, provide:

1. A list of new test files with a one-line description each.
2. A short note on any OS assumptions (e.g., “Linux-only for rogue process experiment using /proc”).
3. A summary of any invariant you discovered that was violated, and the fixes you applied (if any).

Your output should be a PR-ready state of the repo with all tests and examples still passing plus the new fail-fast experiments implemented as described.
```
