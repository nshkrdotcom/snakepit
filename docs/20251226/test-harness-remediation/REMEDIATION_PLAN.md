# Test Harness Remediation Plan

> Date: 2025-12-26
> Status: Critical Design Review
> Author: Engineering Review

## Executive Summary

Three concurrent investigations revealed interconnected failures in the test harness. This document identifies the **fundamental design violation** that causes all observed symptoms and proposes a surgical fix.

## The Fundamental Design Violation

**OTP Anti-Pattern: Blocking `receive` inside GenServer callbacks**

The root cause of all observed failures is a single design violation in `lib/snakepit/pool/pool.ex`:

```elixir
# pool.ex:1608-1616 - THE VIOLATION
defp wait_for_batch_delay(delay_ms) do
  ref = make_ref()
  Process.send_after(self(), {:startup_batch_delay, ref}, delay_ms)

  receive do
    {:startup_batch_delay, ^ref} -> :ok  # <-- BLOCKS THE GENSERVER
  end
end
```

This is called from `handle_continue(:initialize_workers, ...)`, which means:

1. **The Pool GenServer is unresponsive** during batch delays (750ms × N batches)
2. **Shutdown signals cannot be processed** while blocked in `receive`
3. **WorkerSupervisor terminates first** (due to supervision tree order)
4. **Pool resumes after the delay** and tries to call a dead supervisor

This violates the fundamental OTP principle: **GenServer callbacks must return promptly**.

## Observed Symptoms

### Symptom 1: Worker Startup Failures

```
Worker startup task failed: {:shutdown, {GenServer, :call, [Snakepit.Pool.WorkerSupervisor, ...
** (EXIT) no process: the process is not alive
```

**Cause**: Pool's `handle_continue` is blocked in `receive`. Application.stop terminates WorkerSupervisor. Pool wakes from `receive` and calls dead supervisor.

### Symptom 2: Orphaned Python Processes

```
Found orphaned process 2431244 (worker: default_worker_2_8067) from previous BEAM run svvavaj
```

**Cause**: `ExUnit.after_suite` returns before cleanup completes. The blocking nature of Pool means it can't respond to shutdown signals promptly, leaving processes orphaned.

### Symptom 3: 32 Workers Instead of 2

```
pool_size: 2, startup_batch_size: 8
... default_worker_32_6285 ...
```

**Cause**: Test configuration pollution. Tests modify `:pools` but don't clear `:pool_config`. When multi-pool mode activates, it falls back to `@default_size` (System.schedulers_online() * 2 = 32 on 16-core).

## Critical Review of Agent Findings

### Agent 1: Worker Startup Race (Correct Root Cause)

The agent correctly identified the race condition:

```
Timeline:
T=0: Pool.init returns {:continue, :initialize_workers}
T=1: handle_continue begins batch 0
T=2: wait_for_batch_delay(750) BLOCKS the GenServer
T=3: Test calls Application.stop(:snakepit)
T=4: WorkerSupervisor terminates (reverse order)
T=5: Pool's receive times out, resumes
T=6: Pool calls WorkerSupervisor.start_worker -> CRASH
```

**Assessment**: Correct. This is the primary failure mode.

### Agent 2: Orphaned Process Cleanup (Correct Secondary Issue)

The agent identified that `after_suite` doesn't wait for completion:

```elixir
ExUnit.after_suite(fn _results ->
  Application.stop(:snakepit)  # Initiates, doesn't wait
  wait_for_worker_shutdown(...)  # Only polls pgrep, not app state
  :ok  # Returns before cleanup completes
end)
```

**Assessment**: Correct, but this is a symptom of the fundamental issue. If Pool could respond to shutdown signals, cleanup would be faster and more deterministic.

### Agent 3: Pool Size Mismatch (Correct Tertiary Issue)

The agent identified test configuration pollution:

```elixir
# Test sets :pools but doesn't clear :pool_config
Application.put_env(:snakepit, :pools, [...])
Application.put_env(:snakepit, :pooling_enabled, true)
# :pool_config still has pool_size: 2 from config/test.exs
```

**Assessment**: Correct, but this is a test hygiene issue. The pool_size fix in pool.ex is correct; tests just need proper cleanup.

## The Fix Hierarchy

### Priority 1: Eliminate Blocking Receive (CRITICAL)

Replace `wait_for_batch_delay` with message-based async pattern:

```elixir
# BEFORE (blocking)
defp wait_for_batch_delay(delay_ms) do
  ref = make_ref()
  Process.send_after(self(), {:startup_batch_delay, ref}, delay_ms)
  receive do
    {:startup_batch_delay, ^ref} -> :ok
  end
end

# AFTER (async)
defp schedule_next_batch(state, batch_num, delay_ms) do
  ref = make_ref()
  Process.send_after(self(), {:continue_batch, batch_num, ref}, delay_ms)
  %{state | pending_batch: {batch_num, ref}}
end

def handle_info({:continue_batch, batch_num, ref}, state) do
  if state.pending_batch == {batch_num, ref} do
    # Process next batch
    {:noreply, start_next_batch(state, batch_num)}
  else
    # Stale message, ignore
    {:noreply, state}
  end
end
```

### Priority 2: Add Supervisor Health Checks

Before starting workers, verify supervisor is alive:

```elixir
defp start_worker_in_batch(worker_ctx, i) do
  case Process.whereis(Snakepit.Pool.WorkerSupervisor) do
    nil ->
      {:error, :supervisor_dead}
    _pid ->
      start_worker_legacy(worker_ctx, i)
  end
end
```

### Priority 3: Synchronous Test Cleanup

Make `after_suite` wait for actual completion:

```elixir
ExUnit.after_suite(fn _results ->
  # Monitor the supervisor before stopping
  sup_pid = Process.whereis(Snakepit.Supervisor)
  ref = if sup_pid, do: Process.monitor(sup_pid)

  Application.stop(:snakepit)

  # Wait for supervisor to actually terminate
  if ref do
    receive do
      {:DOWN, ^ref, :process, ^sup_pid, _} -> :ok
    after
      10_000 -> :timeout
    end
  end

  # Then wait for OS processes
  wait_for_worker_shutdown(beam_run_id, deadline)
end)
```

### Priority 4: Test Configuration Hygiene

Ensure ALL tests restore ALL env keys:

```elixir
setup do
  # Capture ALL relevant keys
  prev = %{
    pools: Application.get_env(:snakepit, :pools),
    pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
    pool_config: Application.get_env(:snakepit, :pool_config),
    adapter_module: Application.get_env(:snakepit, :adapter_module)
  }

  on_exit(fn ->
    # Restore ALL keys
    Enum.each(prev, fn {key, value} ->
      if value == nil do
        Application.delete_env(:snakepit, key)
      else
        Application.put_env(:snakepit, key, value)
      end
    end)
  end)
end
```

## Implementation Order

1. **Day 1: Fix blocking receive in Pool** (Priority 1)
   - Convert `wait_for_batch_delay` to async message pattern
   - Add `handle_info` clause for `:continue_batch`
   - Track pending batch in state

2. **Day 1: Add supervisor health checks** (Priority 2)
   - Check `Process.whereis` before starting workers
   - Return `{:error, :supervisor_dead}` early

3. **Day 2: Fix test harness** (Priority 3)
   - Make after_suite wait for supervisor DOWN
   - Add timeout handling

4. **Day 2: Add test regression coverage** (Priority 4)
   - Test that shutdown during batch startup doesn't crash
   - Test that orphan cleanup runs deterministically

## Verification Criteria

After fixes are applied:

1. `mix test --include python_integration` produces NO orphan warnings
2. Running tests twice in succession has zero orphan detection
3. Forced shutdown during worker startup doesn't produce cascading crashes
4. `pool_size: 2` in config means exactly 2 workers start

## Architecture Lessons Learned

1. **Never block in GenServer callbacks** - Use async messages
2. **Supervision tree order matters** - Children terminate in reverse
3. **Test cleanup must be synchronous** - Initiate AND wait for completion
4. **Test hygiene requires capturing ALL state** - Not just what you modify

## Files to Modify

| File | Change |
|------|--------|
| `lib/snakepit/pool/pool.ex` | Replace blocking receive with async pattern |
| `test/test_helper.exs` | Wait for supervisor DOWN in after_suite |
| `test/support/test_case.ex` | Add comprehensive env capture/restore |
| `test/snakepit/bridge/python_integration_test.exs` | Add proper cleanup |

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Async batch timing changes behavior | Keep same delays, just non-blocking |
| Supervisor check adds latency | Check is O(1) ETS lookup |
| Longer test cleanup | Better than orphan processes |
