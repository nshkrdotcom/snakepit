# Continuation Prompt — Robust Process Management Heartbeat Workstream  
_Created: 2025-10-18_  

## Current State Snapshot

- **Repository:** `snakepit` (Elixir OTP application with Python bridge)  
- **Feature Track:** Robust Process Management (v0.7.0_1-01), Phase 1 (Heartbeat foundation)  
- **Progress:**  
  - ✅ `Snakepit.HeartbeatMonitor` implemented (`lib/snakepit/heartbeat_monitor.ex`) with unit coverage in `test/snakepit/heartbeat_monitor_test.exs`.  
  - ✅ Initial heartbeat-focused integration spec scaffolded (`test/snakepit/grpc/heartbeat_integration_test.exs`).  
  - ⚠️ Integration tests currently failing because `Snakepit.GRPCWorker` and adapter stack do **not** yet wire in the heartbeat monitor. Python side heartbeat client not started.  
  - No proto changes, Python heartbeat client, or telemetry updates applied yet.  

Use this prompt to resume development with full context and authoritative references.

---

## Required Reading & Reference Materials

### 1. Product & Feature Specifications

- `.kiro/specs/v0.7.0_1-01_robust-process-management/overview.md`  
  High-level rationale, success criteria, architecture overview for heartbeat, self-termination, watchdog, telemetry, and testing expectations.

- `.kiro/specs/v0.7.0_1-01_robust-process-management/design.md`  
  Detailed design blueprint; includes pseudo-code for `Snakepit.HeartbeatMonitor`, heartbeat client, watchdog scripts, telemetry schemas, config examples.

- `.kiro/specs/v0.7.0_1-01_robust-process-management/requirements.md`  
  Acceptance criteria (12 requirement groups) for zero orphans, heartbeat responsiveness, self-terminating workers, telemetry, performance, configurability, testing, and documentation.

- `.kiro/specs/v0.7.0_1-01_robust-process-management/tasks.md`  
  Task decomposition across phases (heartbeat foundation → self-termination → watchdog → telemetry → hardening). Treat as authoritative checklist; each subtask must be implemented/tested.

- `ARCHITECTURE.md`  
  System overview—understand where Pool, WorkerSupervisor, ProcessRegistry, and Python bridge fit. Useful for verifying integration points.

- `README_PROCESS_MANAGEMENT.md`  
  Describes existing process cleanup patterns, run IDs, registry behavior. Ensure new heartbeat/watchdog features align with current cleanup logic.


### 2. Core Elixir Code (existing implementation to extend)

Review these files to understand current lifecycle mechanics, where heartbeat hooks must integrate, and telemetry/process cleanup touchpoints:

1. `lib/snakepit/grpc_worker.ex`  
   - Worker init flow, port spawn, connection establishment, health checks, terminate/2 cleanup.  
   - Identify where to start/stop heartbeat monitor and propagate configs.  

2. `lib/snakepit/pool/pool.ex`  
   - Worker ready notifications, request routing, session affinity.  
   - Check how heartbeat-triggered failures should notify pool (likely via restart path).

3. `lib/snakepit/pool/worker_starter.ex` & `lib/snakepit/pool/worker_supervisor.ex`  
   - Worker supervision strategy, restart semantics.  
   - Understand how heartbeat-triggered terminations interact with restart loop.

4. `lib/snakepit/pool/process_registry.ex`  
   - PID tracking, run ID cleanup. Ensure heartbeat events respect existing registration/unregistration flow.

5. `lib/snakepit/process_killer.ex`  
   - Escalation strategy (SIGTERM → SIGKILL). Heartbeat failure handling will likely call into this.

6. `lib/snakepit/worker/lifecycle_manager.ex`  
   - Worker recycling; double-check whether heartbeat stats need to integrate (telemetry hooks, recycling triggers).

7. `lib/snakepit/application.ex`  
   - Supervision tree; ensure new processes (heartbeat monitor, watchdog manager) slot into correct place.

8. `lib/snakepit/telemetry.ex`  
   - Existing telemetry setup to extend with process-centric events (Phase 4).

9. `lib/snakepit/config.ex`  
   - Configuration normalization; heartbeat settings must flow through pool/worker config here.


### 3. Python Bridge Code

1. `priv/python/grpc_server.py`  
   - Current gRPC server main, signal handling. Identify where to integrate heartbeat client, process group creation, BEAM PID injection, broken-pipe detection.

2. `priv/python/snakepit_bridge/session_context.py`  
   - Understand gRPC stub usage patterns; heartbeat client will follow similar design for calling back to Elixir.

3. (Upcoming) new files to create per spec:  
   - `priv/python/snakepit_bridge/heartbeat.py` (heartbeat client)  
   - Process utilities for process-group management.  


### 4. Test Infrastructure

- `test/snakepit/heartbeat_monitor_test.exs`  
  Newly added unit tests; ensure you maintain them while refactoring (`mix test test/snakepit/heartbeat_monitor_test.exs` currently passes).

- `test/snakepit/grpc/heartbeat_integration_test.exs`  
  New integration test scaffold (currently failing). Used to validate GRPCWorker heartbeat wiring. Update as features mature.

- Existing test suites to touch later:  
  - `test/snakepit/pool/*.exs` (worker lifecycle, cleanup).  
  - `test/chaos/`, `test/integration/` once Phase 2+ tasks start.  


### 5. Tooling & Scripts

- `test/support/mock_grpc_server.sh` and `test/support/mock_grpc_worker.ex`  
  Understand fake gRPC server behavior; integration tests may rely on these.

- Process cleanup scripts once watch-dogging begins (`priv/scripts` to be created).


---

## Known Issues & TODOs

1. **HeartbeatMonitor Integration**  
   - Need to update `Snakepit.GRPCWorker` state struct & lifecycle: start monitor after `worker_ready`, pass ping callback, store monitor PID, stop monitor during terminate.  
   - Configure via worker config (heartbeat block). Add defaults & toggles.
   - Ensure heartbeat monitor triggers worker shutdown (`Process.exit(worker_pid, {:shutdown, ...})` currently done in monitor default).

2. **Testing Gap**  
   - `test/snakepit/grpc/heartbeat_integration_test.exs` fails because GRPCWorker never emits `{:heartbeat_monitor_started, ...}`. After implementation, adjust events/expectations accordingly.  
   - Expand integration test coverage (e.g., ensure monitor stops, respects `enabled: false`).

3. **Remaining Phases**  
   - Python heartbeat client, proto changes, process groups, BEAM PID monitoring, watchdog scripts, telemetry, docs. None implemented yet. Follow spec tasks sequentially.


---

## Continuation Directions (TDD Workflow)

Follow strict Red → Green → Refactor → Integrate loop for each acceptance criterion.

1. **Re-run Baseline Tests**  
   - `mix test test/snakepit/heartbeat_monitor_test.exs` (should pass).  
   - `mix test test/snakepit/grpc/heartbeat_integration_test.exs` (expect failures—use as red tests).  

2. **Implement Heartbeat Integration for `Snakepit.GRPCWorker`**  
   - Modify `lib/snakepit/grpc_worker.ex` to:
     - Parse heartbeat config (`worker_config[:heartbeat]`), default to enabled with spec defaults.
     - Start `Snakepit.HeartbeatMonitor` after connection success (likely in `handle_continue(:connect_and_wait)` once worker_ready acknowledged).  
       - Provide `ping_fun` callback that uses adapter gRPC to send Ping.  
       - Include instrumentation hook to notify tests (e.g., send `{:heartbeat_monitor_started, worker_id, monitor_pid}` when `test_pid` provided).  
     - Handle monitor termination in `terminate/2` (call `GenServer.stop/1` or monitor).  
     - Propagate monitor events to state for later telemetry.
   - Ensure worker handles monitor-induced shutdown gracefully.

3. **Update Tests**  
   - Evolve `test/snakepit/grpc/heartbeat_integration_test.exs` to assert real behavior (no reliance on `test_pid` hack long-term; adapt to actual monitor wiring).  
   - Keep tests deterministic—use `Process.monitor`, `assert_receive`, `assert_eventually`.

4. **Refactor & Document**  
   - Once tests pass, clean up instrumentation/test hooks (guard behind config/test env).  
   - Update module docs, add @doc for new functions.  
   - Run `mix format`.

5. **Prepare for Next Steps**  
   - Plan proto updates and Python heartbeat client (Task 1.2 & 1.3).  
   - Extract configuration defaults into `Snakepit.Config` if needed.

---

## Command Checklist (use selectively)

```bash
# Unit tests
mix test test/snakepit/heartbeat_monitor_test.exs

# Heartbeat integration suite (expect RED until integration implemented)
mix test test/snakepit/grpc/heartbeat_integration_test.exs

# Full lint/format pass after implementation
mix format
mix compile --warnings-as-errors
```

For Python work (later phases):

```bash
cd priv/python && pytest tests/ -q
```

---

## Reporting & Handoff Expectations

When you pause again, capture:

1. Current test status (which suites pass/fail).  
2. Summary of code changes with file references.  
3. Outstanding TODOs/risks vs. requirements checklist.  
4. Next TDD target (which acceptance criterion/test to tackle next).  

Keep commits atomic and aligned with the task list (one logical feature per commit). Ensure no unrelated files are modified.

---

## Reminder: Acceptance Criteria Compliance

While working through the heartbeat phase, continually cross-check the following requirements from `requirements.md`:

- Req 1.2 & 1.3 (graceful/forced shutdown via heartbeat detection).  
- Req 2.1–2.5 (heartbeat responsiveness, restart triggers, configurability, low overhead).  
- Req 5.1–5.3 (telemetry—plan instrumentation once core loop works).  
- Req 6 (ensure integration with worker lifecycle).  
- Req 9.1–9.4 (config options need to be surfaced).  

Future phases will cover Req 3+, but design decisions now should anticipate those needs.

---

### Ready to Continue

Begin by re-running the tailored test commands, observe current failures, and follow the TDD plan to implement heartbeat integration in `Snakepit.GRPCWorker`. Once GREEN, proceed to proto & Python heartbeat client work per spec. Keep this prompt open as your navigation map. Good luck!  
