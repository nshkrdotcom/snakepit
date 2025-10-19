# Implementation Prompt — Robust Process Management (v0.7.0_1-01)

You are tasked with delivering the entire Robust Process Management feature for Snakepit v0.7.0. Follow a strict red/green/debug TDD loop until all acceptance criteria in the spec are satisfied and all automated tests pass.

## CRITICAL: Required Source Code Review (complete BEFORE reading specs)

**DO NOT assume the documentation is accurate.** You MUST review the actual source code first to understand the current implementation:

### Core Worker Process Management (PRIORITY 1)
1. **`lib/snakepit/grpc_worker.ex`** - Primary worker GenServer that manages Python processes
   - How Python processes are spawned (Port.open with spawn_executable)
   - Current process cleanup in terminate/2 (uses ProcessKiller)
   - Port monitoring and EXIT_STATUS handling
   - Worker registration with ProcessRegistry
2. **`lib/snakepit/pool/pool.ex`** - Pool manager with worker availability tracking
   - Worker checkout/checkin logic
   - Session affinity caching (ETS)
   - How worker_ready notifications work
3. **`lib/snakepit/pool/worker_starter.ex`** - Supervisor wrapper for individual workers
   - Transient restart strategy
   - Shutdown timeout (5000ms)
4. **`lib/snakepit/process_killer.ex`** - Current process management utilities
   - kill_process/2 - signal sending (:sigterm, :sigkill)
   - kill_with_escalation/2 - SIGTERM → wait → SIGKILL pattern
   - process_alive?/1 - kill -0 checking
   - kill_by_run_id/1 - bulk cleanup by run ID

### Python Process Side (PRIORITY 1)
5. **`priv/python/grpc_server.py`** - Python gRPC server main entry point
   - Signal handling setup (SIGTERM, SIGINT)
   - Shutdown event handling
   - wait_for_elixir_server - connection validation
   - serve_with_shutdown - main server loop
6. **`priv/python/snakepit_bridge/session_context.py`** - Session state management
   - How Python communicates back to Elixir SessionStore
   - gRPC stub usage

### Support Infrastructure (PRIORITY 2)
7. **`lib/snakepit/pool/process_registry.ex`** - Process tracking registry
8. **`lib/snakepit/pool/worker_supervisor.ex`** - DynamicSupervisor for workers
9. **`lib/snakepit/worker/lifecycle_manager.ex`** - Worker recycling/lifecycle
10. **`lib/snakepit/telemetry.ex`** - Current telemetry implementation
11. **`lib/snakepit/application.ex`** - Supervision tree and startup

### Test Infrastructure (PRIORITY 2)
12. **`test/snakepit/grpc_worker_test.exs`** (if exists)
13. **`test/snakepit/pool/pool_test.exs`** (if exists)
14. Integration tests for worker lifecycle

## After Code Review: Read Specifications

- `.kiro/specs/v0.7.0_1-01_robust-process-management/overview.md`
- `.kiro/specs/v0.7.0_1-01_robust-process-management/design.md`
- `.kiro/specs/v0.7.0_1-01_robust-process-management/requirements.md`
- `.kiro/specs/v0.7.0_1-01_robust-process-management/tasks.md`
- `ARCHITECTURE.md` (reference for context)
- `README_PROCESS_MANAGEMENT.md` (if exists)

## Current Implementation Assessment (as of source review)

### What EXISTS and WORKS:
1. **Process Cleanup Infrastructure**
   - `Snakepit.ProcessKiller` - POSIX-compliant kill with escalation (SIGTERM → SIGKILL)
   - `GRPCWorker.terminate/2` - Calls ProcessKiller with 2000ms timeout
   - `Worker.Starter` - Transient restart with 5000ms shutdown
   - Process.flag(:trap_exit, true) in both Pool and GRPCWorker
   - Port monitoring via Port.monitor in GRPCWorker

2. **Python Signal Handling**
   - grpc_server.py has SIGTERM/SIGINT handlers
   - Shutdown event for graceful termination
   - asyncio-based server lifecycle

3. **Process Tracking**
   - ProcessRegistry tracks worker_id → PID mappings
   - run_id-based cleanup for orphan prevention
   - Port info extraction for os_pid

### What is MISSING (implement per spec):
1. **NO Heartbeat Monitoring** - No HeartbeatMonitor GenServer exists
2. **NO Python-side Heartbeat Client** - No self-termination on BEAM death
3. **NO Pipe Monitoring** - Python doesn't detect broken stdout/stderr
4. **NO BEAM PID Monitoring** - Python doesn't monitor BEAM process existence
5. **NO Process Groups** - No atomic child process cleanup
6. **NO Watchdog Scripts** - No external process monitor
7. **LIMITED Telemetry** - Basic telemetry exists but not process-lifecycle-specific events

## Scope & Deliverables

Implement every task listed in `tasks.md`, respecting ordering and dependencies:

1. **Heartbeat foundation (Elixir & Python)**
   - NEW: Create `Snakepit.HeartbeatMonitor` GenServer
   - EXTEND: Add heartbeat integration to `GRPCWorker`
   - NEW: Add heartbeat gRPC service to .proto
   - NEW: Python `HeartbeatClient` class in `snakepit_bridge/heartbeat.py`
   - INTEGRATE: Connect heartbeat to existing worker lifecycle

2. **Self-termination & cleanup**
   - EXTEND: Python signal handlers with BrokenPipeError detection
   - NEW: BEAM PID monitoring in Python (os.kill(pid, 0) checks)
   - NEW: Process group management (os.setpgrp on Linux/macOS)
   - EXTEND: Emergency shutdown hooks (os._exit on BEAM crash)
   - VERIFY: Tie into existing ProcessKiller and restart logic

3. **Optional watchdog process**
   - NEW: Shell scripts (priv/scripts/watchdog.sh, watchdog.bat)
   - NEW: Watchdog integration in GRPCWorker init
   - NEW: Platform-specific implementations

4. **Telemetry & monitoring**
   - NEW: `Snakepit.ProcessTelemetry` module
   - EXTEND: Add telemetry emissions to HeartbeatMonitor
   - EXTEND: Add telemetry to worker lifecycle events
   - INTEGRATE: With existing `Snakepit.Telemetry`

5. **Testing & hardening**
   - NEW: Chaos tests for BEAM crashes
   - NEW: Integration tests for heartbeat
   - NEW: Process orphan verification tests
   - EXTEND: Existing test suites

Use the detailed subtasks in `tasks.md` as your authoritative checklist. Do not skip any acceptance criteria in `requirements.md`.

## Development Constraints & Best Practices

### Backward Compatibility (CRITICAL)
- **DO NOT** change existing public API signatures in Pool, GRPCWorker, or ProcessKiller
- **DO NOT** break existing worker initialization flow (Worker.Starter → GRPCWorker.init)
- **DO** make heartbeat monitoring optional via configuration (enabled by default)
- **DO** maintain existing signal escalation behavior in ProcessKiller
- **DO** preserve existing ProcessRegistry registration flow

### Integration with Existing Code
- **ProcessKiller**: Use existing kill_with_escalation/2, don't duplicate logic
- **GRPCWorker.terminate/2**: Enhance, don't replace - already has graceful shutdown
- **Python signal handlers**: Extend existing handle_signal in grpc_server.py
- **Telemetry**: Use existing :telemetry.execute/3 patterns from Snakepit.Telemetry
- **Port monitoring**: Build on existing Port.monitor in GRPCWorker
- **Process tracking**: Use ProcessRegistry.activate_worker/4 pattern

### Code Quality & Testing
- Follow repository formatting standards (`mix format`, `black` for Python)
- Every new module must have >95% test coverage
- Write tests FIRST (TDD): Red → Green → Refactor
- Test both success and failure paths
- Include chaos tests for crash scenarios (SIGKILL, network issues)
- Validate telemetry event emissions in tests

### Documentation Requirements
- Update or add docs where spec requires (telemetry, ops guides, configuration)
- Add @moduledoc to all new Elixir modules
- Add docstrings to all new Python classes/functions
- Document configuration options with examples
- Include troubleshooting guides for common issues

## TDD Workflow (STRICT)

Follow this cycle for EVERY feature:

1. **RED Phase**
   - Write a failing test that captures ONE requirement from requirements.md
   - Verify the test fails for the right reason
   - Example: Test that HeartbeatMonitor detects timeout after 3 missed pings

2. **GREEN Phase**
   - Implement MINIMAL code to make the test pass
   - DO NOT add features not covered by the current test
   - Verify test passes: `mix test path/to/test_file.exs:line_number`

3. **REFACTOR Phase**
   - Clean up code while keeping tests green
   - Add logging and telemetry
   - Format code: `mix format`
   - Run full test suite to ensure no regressions

4. **INTEGRATE Phase**
   - Verify integration with existing code
   - Check backward compatibility
   - Run related tests: `mix test test/snakepit/`

5. **REPEAT** until all acceptance criteria satisfied

## Required Test Commands & Validation

### Per-Feature Tests (during development)
```bash
# Run specific test file
mix test test/snakepit/heartbeat_monitor_test.exs

# Run specific test
mix test test/snakepit/heartbeat_monitor_test.exs:42

# Run with detailed output
mix test test/snakepit/heartbeat_monitor_test.exs --trace
```

### Python Tests (when adding Python code)
```bash
# Run Python tests
cd priv/python && pytest tests/ -v

# Run specific test
cd priv/python && pytest tests/test_heartbeat.py::test_broken_pipe_detection
```

### Full Test Suite (before committing)
```bash
# All Elixir tests
mix test

# With coverage
mix test --cover

# Python tests
cd priv/python && pytest tests/ -q
```

### Chaos/Integration Tests (before marking task complete)
```bash
# Run chaos tests for process management
mix test test/chaos/process_management_chaos_test.exs

# Run integration tests
mix test test/integration/
```

## Key Implementation Insights (from source code review)

### GRPCWorker Process Lifecycle
```elixir
# Current flow (lib/snakepit/grpc_worker.ex):
init/1:
  - Process.flag(:trap_exit, true)  # Enables terminate/2 callback
  - ProcessRegistry.reserve_worker(worker_id)
  - Port.open({:spawn_executable, python_executable})
  - Port.monitor(server_port)  # Monitor for port death
  - ProcessRegistry.activate_worker(worker_id, self(), python_pid)
  - {:ok, state, {:continue, :connect_and_wait}}

handle_continue(:connect_and_wait):
  - wait_for_server_ready(port, 30000)  # Waits for "GRPC_READY:port" message
  - GenServer.call(pool, {:worker_ready, worker_id})  # Notifies pool

terminate/2:
  - ProcessKiller.kill_with_escalation(python_pid, 2000)  # SIGTERM → wait → SIGKILL
  - GRPC.Stub.disconnect(channel)
  - ProcessRegistry.unregister_worker(worker_id)
```

**Integration Points for Heartbeat:**
- Add HeartbeatMonitor start in `handle_continue(:connect_and_wait)` after worker_ready
- Store monitor PID in state: `%{state | heartbeat_monitor: monitor_pid}`
- Stop monitor in `terminate/2` before ProcessKiller
- Use existing Port for stdio pipe monitoring

### Python Server Lifecycle
```python
# Current flow (priv/python/grpc_server.py):
main():
  - signal.signal(SIGTERM, handle_signal)  # Graceful shutdown
  - signal.signal(SIGINT, handle_signal)   # Ctrl+C
  - shutdown_event = asyncio.Event()
  - asyncio.run(serve_with_shutdown(port, adapter, elixir_address, shutdown_event))

serve_with_shutdown():
  - wait_for_elixir_server(elixir_address)  # Validates Elixir is up
  - server.start()
  - logger.info(f"GRPC_READY:{port}")  # Signals to Elixir
  - await shutdown_event.wait()  # Blocks until signal
  - server.stop(0.5)  # 500ms grace period
```

**Integration Points for Self-Termination:**
- Add HeartbeatClient thread start before `shutdown_event.wait()`
- Pass BEAM PID via --beam-pid argument (get from `System.pid()` in Elixir)
- Monitor both shutdown_event AND heartbeat client failure
- Call `shutdown_event.set()` on broken pipe or BEAM death detection

### Critical Race Conditions to Handle
1. **Worker startup vs. Pool shutdown**
   - GRPCWorker checks if Pool is alive before calling worker_ready
   - HeartbeatMonitor must do same check before registering

2. **Python process vs. Port closure**
   - terminate/2 may be called while Python is starting
   - ProcessKiller must handle "No such process" gracefully (already does)

3. **Heartbeat timeout vs. Worker restart**
   - Worker.Starter will auto-restart crashed workers
   - HeartbeatMonitor timeout should trigger graceful stop, not brutal kill
   - Let Worker.Starter handle the restart

### Configuration Integration
Current config structure (check `lib/snakepit/config.ex`):
```elixir
# Add to pool_config or worker_config:
heartbeat: %{
  enabled: true,  # Default enabled
  ping_interval_ms: 2_000,
  timeout_threshold_ms: 10_000,
  max_missed_heartbeats: 3
},
watchdog: %{
  enabled: false,  # Default disabled (optional)
  check_interval_s: 1,
  grace_period_s: 3
}
```

## Completion Criteria (DO NOT SKIP)

Before marking this feature complete, verify ALL of the following:

### Functional Requirements
- [ ] All tests pass: `mix test` returns 0 failures
- [ ] Python tests pass: `cd priv/python && pytest tests/`
- [ ] Chaos tests demonstrate zero orphans after BEAM kill
- [ ] HeartbeatMonitor detects unresponsive workers within 10s
- [ ] Python workers self-terminate within 5s of BEAM crash
- [ ] Watchdog scripts work on Linux and macOS (test manually)

### Code Quality
- [ ] All new modules have @moduledoc and @doc annotations
- [ ] Code formatted: `mix format --check-formatted`
- [ ] No compiler warnings: `mix compile --warnings-as-errors`
- [ ] Test coverage >95%: `mix test --cover`
- [ ] Dialyzer passes: `mix dialyzer` (if configured)

### Integration & Backward Compatibility
- [ ] Existing tests still pass (no regressions)
- [ ] Pool can be started with heartbeat disabled
- [ ] Worker restart behavior unchanged (Worker.Starter still works)
- [ ] ProcessKiller escalation behavior preserved
- [ ] No breaking changes to public APIs

### Documentation & Observability
- [ ] Telemetry events documented in ProcessTelemetry module
- [ ] Configuration options documented with examples
- [ ] Troubleshooting guide includes common failure scenarios
- [ ] All new functions have usage examples in @doc
- [ ] Logging provides clear diagnostic information

### Production Readiness
- [ ] Performance impact measured and < 1% CPU overhead
- [ ] No memory leaks in long-running tests (run pool for 10+ minutes)
- [ ] Graceful degradation when heartbeat fails
- [ ] Clear error messages for misconfiguration
- [ ] Operational runbook includes monitoring recommendations

---

## Summary: Source Code → Spec → Implementation Path

**You have reviewed the source code and understand:**
1. ✅ How GRPCWorker currently manages Python processes (Port.open, Port.monitor)
2. ✅ How terminate/2 uses ProcessKiller with escalation (SIGTERM → SIGKILL)
3. ✅ How Python handles signals (SIGTERM/SIGINT → shutdown_event)
4. ✅ How Pool manages worker lifecycle (worker_ready notifications, checkin/checkout)
5. ✅ How ProcessRegistry tracks PIDs (reserve → activate → unregister)

**Now follow this path:**
1. **Read specs** in order: overview.md → design.md → requirements.md → tasks.md
2. **Identify gaps** between current implementation and spec requirements
3. **Plan phases** per tasks.md (Phase 1: Heartbeat, Phase 2: Self-termination, etc.)
4. **TDD each feature** following Red → Green → Refactor → Integrate cycle
5. **Verify completion** against all checkboxes above

**Remember:**
- Specs describe the IDEAL state
- Source code shows the ACTUAL state
- Your job: Bridge the gap with minimal disruption
- When in doubt: Preserve existing behavior, add new capabilities via configuration

**First step after reading this:** Open requirements.md and convert each acceptance criterion into a test case. Write those tests first. Then make them pass.
