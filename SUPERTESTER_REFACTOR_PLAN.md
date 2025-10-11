# Snakepit Test Suite Refactoring Plan
## Supertester Conformance & Quality Improvements

**Document Version:** 1.0
**Date:** 2025-10-10
**Author:** Claude Code Analysis
**Status:** Planning Phase

---

## Executive Summary

This document outlines a comprehensive plan to refactor the Snakepit test suite to achieve full conformance with Supertester patterns and identify low-risk improvements that will increase test reliability, reduce flakiness, and improve maintainability.

**Current State:**
- ✅ Foundation in place: Using `Supertester.TestCase` with basic isolation
- ❌ Not using core Supertester helpers (0% adoption)
- ❌ Extensive Process.sleep usage (15+ violations across 11 files)
- ⚠️ Custom implementations that duplicate Supertester functionality
- ⚠️ Sub-optimal isolation level (`:basic` vs recommended `:full_isolation`)

**Target State:**
- ✅ Zero `Process.sleep` in test code
- ✅ 100% use of Supertester helpers for OTP operations
- ✅ Full test isolation with `:full_isolation` mode
- ✅ Deterministic, parallel-safe test suite
- ✅ Improved test expressiveness and maintainability

---

## Table of Contents

1. [Current State Analysis](#1-current-state-analysis)
2. [Supertester Conformance Issues](#2-supertester-conformance-issues)
3. [Refactoring Strategy](#3-refactoring-strategy)
4. [Implementation Plan](#4-implementation-plan)
5. [Risk Assessment](#5-risk-assessment)
6. [Low-Risk Improvements](#6-low-risk-improvements)
7. [Testing the Refactor](#7-testing-the-refactor)
8. [Rollout Plan](#8-rollout-plan)

---

## 1. Current State Analysis

### 1.1 Test Infrastructure

**Files:**
- `test/support/test_case.ex` - Base test case with Supertester integration
- `test/support/test_helpers.ex` - Custom helpers (some duplicate Supertester)
- `test/support/mock_adapters.ex` - Mock implementations for testing
- `test/support/python_integration_case.ex` - Integration test setup
- `test/test_helper.exs` - Global test configuration

**Current Setup:**
```elixir
# test/support/test_case.ex
defmodule Snakepit.TestCase do
  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
      use Supertester.UnifiedTestFoundation, isolation: :basic  # ⚠️ Should be :full_isolation

      import Supertester.OTPHelpers          # ✅ Imported but NOT USED
      import Supertester.GenServerHelpers    # ✅ Imported but NOT USED
      import Supertester.Assertions          # ✅ Imported but NOT USED
      import Snakepit.TestHelpers
    end
  end
end
```

### 1.2 Test File Inventory

**Total Test Files:** 12 test files (excluding support files)

| File | LOC | Async | Process.sleep | Violations |
|------|-----|-------|---------------|------------|
| `worker_lifecycle_test.exs` | 141 | false | 8 | Critical |
| `application_cleanup_test.exs` | 55 | false | 3 | High |
| `session_store_test.exs` | 52 | true | 1 | Medium |
| `grpc_worker_test.exs` | 187 | true | 1 | Low |
| `grpc_worker_mock_test.exs` | 113 | true | 1 | Low |
| `python_integration_test.exs` | 46 | false | 1 | Medium |
| `pool_throughput_test.exs` | 157 | false | 1 | Low |
| `test_helper.exs` | ~50 | N/A | 1 | Medium |

**Total Process.sleep violations:** 17 instances

### 1.3 Production Code Analysis

**Key Production Files:**
- `lib/snakepit/grpc_worker.ex` (630 lines) - Main worker GenServer
- `lib/snakepit/pool/*.ex` - Pool management and supervision
- `lib/snakepit/bridge/*.ex` - Bridge infrastructure

**Worker Synchronization Points:**
1. **Initialization**: `handle_continue(:connect_and_wait)` - Blocking server startup
2. **Worker Ready Notification**: `GenServer.cast(pool_name, {:worker_ready, worker_id})`
3. **Health Checks**: Periodic `:health_check` messages
4. **Cleanup**: `terminate/2` with graceful shutdown logic

**Critical Observation:** `GRPCWorker` does NOT implement `TestableGenServer` behavior!
- Missing `__supertester_sync__` handler
- This prevents use of `cast_and_sync/3` pattern

---

## 2. Supertester Conformance Issues

### 2.1 Critical Violations

#### CV-1: Zero Usage of Core Supertester Helpers

**Issue:** Despite importing Supertester helpers, we don't use ANY of them.

**Impact:**
- Missing out on deterministic synchronization
- Forced to use `Process.sleep` and manual polling
- Tests are fragile and timing-dependent

**Unused Functions:**
```elixir
# From Supertester.OTPHelpers (NEVER USED):
- setup_isolated_genserver/3    # Would replace manual start_link
- setup_isolated_supervisor/3   # Would replace manual supervisor setup
- wait_for_genserver_sync/2     # Would replace Process.sleep
- wait_for_process_restart/3    # Would replace custom helper

# From Supertester.GenServerHelpers (NEVER USED):
- cast_and_sync/3               # CRITICAL for async testing
- get_server_state_safely/1     # Would replace raw :sys.get_state
- test_server_crash_recovery/2  # For crash testing
- concurrent_calls/3            # For stress testing

# From Supertester.Assertions (NEVER USED):
- assert_genserver_state/2      # More expressive than manual checks
- assert_process_alive/1        # Better than Process.alive?
- assert_genserver_responsive/1 # Built-in responsiveness check
```

**Example - Current vs Should Be:**
```elixir
# ❌ CURRENT (test/unit/grpc/grpc_worker_test.exs:8-17)
setup context do
  {worker, _worker_id, port} =
    Snakepit.TestHelpers.create_isolated_worker(context.test, adapter: MockGRPCAdapter)

  assert_receive {:grpc_ready, ^port}, 5_000  # Manual message waiting

  on_exit(fn ->
    if Process.alive?(worker) do
      GenServer.stop(worker)
    end
  end)

  %{worker: worker, port: port}
end

# ✅ SHOULD BE (using Supertester)
setup context do
  test_name = to_string(context.test)

  # Supertester handles naming, cleanup, and synchronization
  {:ok, worker} = setup_isolated_genserver(
    MockGRPCWorker,
    test_name,
    adapter: MockGRPCAdapter
  )

  # Wait for worker to be responsive using OTP pattern
  :ok = wait_for_genserver_sync(worker, 5_000)

  # No need for manual on_exit - Supertester handles it
  %{worker: worker}
end
```

#### CV-2: Extensive Process.sleep Usage (17 Violations)

**Issue:** Timing-based synchronization throughout test suite.

**Why This Matters:**
1. **Flakiness**: Tests pass/fail based on arbitrary timing assumptions
2. **Speed**: Unnecessary waits slow down test suite
3. **CI Issues**: Different environments have different timing characteristics
4. **Non-determinism**: Race conditions can cause sporadic failures

**Breakdown by Severity:**

**CRITICAL (8 instances in worker_lifecycle_test.exs):**
```elixir
# Line 13: Setup cleanup delay
Process.sleep(100)

# Line 26: Waiting for workers to start
Process.sleep(500)  # ❌ Should use wait_for_genserver_sync

# Line 36: Waiting for shutdown
Process.sleep(3000)  # ❌ Should use wait_for_supervisor_stabilization

# Line 58: Waiting for workers to start (again)
Process.sleep(500)

# Line 63: Waiting during normal operation
Process.sleep(1000)

# Line 78: Cleanup delay
Process.sleep(2000)

# Lines 87, 90: Multiple cycle delays
Process.sleep(500)
Process.sleep(2000)
```

**HIGH (3 instances in application_cleanup_test.exs):**
```elixir
# Line 19: Waiting for workers to start
Process.sleep(1000)  # ❌ Should poll for worker readiness

# Line 26: Waiting during operation
Process.sleep(2000)  # ❌ Should verify state, not wait

# Line 42: Cleanup delay
Process.sleep(2000)  # ❌ Should wait for actual cleanup completion
```

**MEDIUM (6 instances across other files):**
- `session_store_test.exs:43` - Waiting for expiration (1100ms)
- `grpc_worker_test.exs:131` - Health check processing (50ms)
- `grpc_worker_mock_test.exs:106` - Registry update (10ms)
- `test_helpers.ex:84` - Supervisor restart (100ms)
- `python_integration_test.exs:34` - Heartbeat spacing (100ms)
- `pool_throughput_test.exs:26` - Pool initialization (100ms)

#### CV-3: Missing TestableGenServer Implementation

**Issue:** `GRPCWorker` doesn't implement Supertester's `TestableGenServer` behavior.

**Current State:**
```elixir
# lib/snakepit/grpc_worker.ex:32
use GenServer  # ❌ Should ALSO use Supertester.TestableGenServer
require Logger
```

**Impact:**
- Cannot use `cast_and_sync/3` pattern
- Must rely on `assert_receive` or `Process.sleep` for async operations
- Tests are less deterministic

**What's Missing:**
```elixir
# TestableGenServer would inject this handler:
def handle_call(:__supertester_sync__, _from, state) do
  {:reply, :ok, state}
end

# And this variant for state inspection:
def handle_call({:__supertester_sync__, return_state: true}, _from, state) do
  {:reply, {:ok, state}, state}
end
```

#### CV-4: Custom Implementations Duplicate Supertester

**Issue:** We've reimplemented functionality that Supertester provides.

**Example - test/support/test_helpers.ex:79-87:**
```elixir
# ❌ CUSTOM IMPLEMENTATION (has bugs!)
def assert_process_restarted(monitor_ref, original_pid, timeout \\ 5_000) do
  assert_receive {:DOWN, ^monitor_ref, :process, ^original_pid, _reason}, timeout
  # Give supervisor time to restart
  Process.sleep(100)  # ⚠️ TIMING ASSUMPTION!
  # Process should be registered again
  assert Process.whereis(original_pid) != nil  # ⚠️ WRONG - original_pid is PID not name!
end

# ✅ SUPERTESTER PROVIDES (robust, tested)
# From Supertester.OTPHelpers:
wait_for_process_restart(process_name, original_pid, timeout \\ 1000)
# - Uses polling with receive timeouts (no sleep)
# - Verifies new process is responsive
# - Handles edge cases properly
```

**Other Duplications:**
- `allocate_test_port/0` - Could use Supertester's port allocation
- `assert_grpc_server_ready/2` - Should use `wait_for_genserver_sync`

### 2.2 Configuration Issues

#### CI-1: Sub-optimal Isolation Level

**Current:** `isolation: :basic` (test_case.ex:10)
**Recommended:** `isolation: :full_isolation` (per Supertester MANUAL.md:120)

**Isolation Modes Comparison:**

| Mode | Process Isolation | ETS Isolation | Registry | Cleanup | Use Case |
|------|-------------------|---------------|----------|---------|----------|
| `:basic` | ✅ Unique names | ❌ Shared | ❌ None | Manual | Simple tests |
| `:registry` | ✅ Unique names | ❌ Shared | ✅ Dedicated | Auto | Most tests |
| `:full_isolation` | ✅ Unique names | ✅ Sandboxed | ✅ Dedicated | Auto | **Production** |
| `:contamination_detection` | ✅ Unique names | ✅ Tracked | ✅ Monitored | Auto | **Debugging** |

**Why `:full_isolation`:**
1. **ETS Safety**: SessionStore uses ETS tables - need isolation
2. **Process Leaks**: Detect if tests leak processes
3. **True Parallelism**: Safe for `async: true` across all tests
4. **Best Practice**: Recommended by Supertester for production code

#### CI-2: Async Configuration Inconsistency

**Issue:** Some tests are `async: false` unnecessarily.

**Current State:**
```elixir
worker_lifecycle_test.exs:6    - async: false  # ❌ Could be true with proper isolation
application_cleanup_test.exs:9 - async: false  # ❌ Could be true with proper isolation
python_integration_test.exs:13 - async: false  # ✅ OK - external Python process
pool_throughput_test.exs:2     - async: false  # ✅ OK - performance benchmark
```

**Recommendation:**
- Use `async: true` by default
- Only use `async: false` for:
  - True integration tests with external resources
  - Performance benchmarks where concurrency affects results
  - Tests that intentionally test application-wide behavior

---

## 3. Refactoring Strategy

### 3.1 Guiding Principles

1. **Incremental Refactoring**: One file at a time, one pattern at a time
2. **Backward Compatibility**: Maintain test coverage throughout
3. **Verify Each Step**: Run tests after each change
4. **Document Changes**: Clear commit messages explaining each transformation
5. **Low Risk First**: Start with simple, low-risk changes

### 3.2 Refactoring Patterns

#### Pattern 1: Replace Process.sleep with wait_for_genserver_sync

**Before:**
```elixir
{:ok, worker} = start_worker()
Process.sleep(500)  # ❌ Hope it's ready
state = :sys.get_state(worker)
```

**After:**
```elixir
{:ok, worker} = start_worker()
:ok = wait_for_genserver_sync(worker, 5_000)  # ✅ Know it's ready
{:ok, state} = get_server_state_safely(worker)
```

**Risk:** Low
**Benefit:** Deterministic synchronization
**Test Impact:** Tests may run faster (no arbitrary waits)

#### Pattern 2: Replace Manual Setup with setup_isolated_genserver

**Before:**
```elixir
test "my test" do
  worker_id = "test_worker_#{System.unique_integer()}"
  {:ok, worker} = MyWorker.start_link(id: worker_id)

  on_exit(fn ->
    if Process.alive?(worker), do: GenServer.stop(worker)
  end)

  # test body
end
```

**After:**
```elixir
test "my test" do
  {:ok, worker} = setup_isolated_genserver(MyWorker, "my_test")
  # Cleanup handled automatically
  # test body
end
```

**Risk:** Low
**Benefit:** Less boilerplate, automatic cleanup
**Test Impact:** Cleaner test code, guaranteed cleanup

#### Pattern 3: Add TestableGenServer to Production Code

**Before:**
```elixir
defmodule Snakepit.GRPCWorker do
  use GenServer
  # ...
end
```

**After:**
```elixir
defmodule Snakepit.GRPCWorker do
  use GenServer
  use Supertester.TestableGenServer  # ✅ Adds sync handler
  # ...
end
```

**Risk:** Very Low (only affects test environment)
**Benefit:** Enables cast_and_sync pattern
**Test Impact:** Can now test async operations deterministically

#### Pattern 4: Replace :sys.get_state with get_server_state_safely

**Before:**
```elixir
state = :sys.get_state(worker)  # ❌ Can crash if worker is down
assert state.count == 5
```

**After:**
```elixir
{:ok, state} = get_server_state_safely(worker)  # ✅ Graceful error handling
assert state.count == 5
```

**Risk:** Very Low
**Benefit:** Better error handling, more explicit
**Test Impact:** Tests won't crash if worker is unexpectedly down

#### Pattern 5: Replace Custom assert_process_restarted

**Before:**
```elixir
ref = Process.monitor(worker)
Process.exit(worker, :kill)
assert_receive {:DOWN, ^ref, :process, ^worker, _}
Process.sleep(100)  # ❌
assert Process.whereis(MyWorker) != nil
```

**After:**
```elixir
original_pid = Process.whereis(MyWorker)
Process.exit(original_pid, :kill)
{:ok, new_pid} = wait_for_process_restart(MyWorker, original_pid, 5_000)  # ✅
assert new_pid != original_pid
```

**Risk:** Low
**Benefit:** Correct implementation, no timing assumptions
**Test Impact:** More reliable restart testing

#### Pattern 6: Replace Polling with assert_eventually

**Before:**
```elixir
create_session(session_id, ttl: 0)
Process.sleep(1100)  # ❌ Hope it expired
cleanup_expired_sessions()
assert {:error, :not_found} = get_session(session_id)
```

**After:**
```elixir
create_session(session_id, ttl: 0)
# Poll until condition is true, with timeout safety
assert_eventually(fn ->
  cleanup_expired_sessions()
  match?({:error, :not_found}, get_session(session_id))
end, timeout: 2000)
```

**Note:** Need to implement `assert_eventually` helper (not in Supertester but common pattern).

**Risk:** Low
**Benefit:** No arbitrary waits, precise timeout handling
**Test Impact:** Faster tests (exits as soon as condition is met)

### 3.3 File-by-File Strategy

**Phase 1: Foundation (Low Risk)**
1. Update `test_case.ex` - Change isolation to `:full_isolation`
2. Add `TestableGenServer` to `GRPCWorker`
3. Add `assert_eventually` helper

**Phase 2: Simple Replacements (Low Risk)**
4. `grpc_worker_test.exs` - Replace Process.sleep(50)
5. `grpc_worker_mock_test.exs` - Replace Process.sleep(10)
6. `pool_throughput_test.exs` - Replace Process.sleep(100)

**Phase 3: Medium Complexity (Medium Risk)**
7. `session_store_test.exs` - Replace sleep with polling
8. `python_integration_test.exs` - Add proper synchronization
9. `test_helpers.ex` - Remove custom implementations

**Phase 4: Complex Refactors (Higher Risk)**
10. `application_cleanup_test.exs` - Full rewrite with proper synchronization
11. `worker_lifecycle_test.exs` - Full rewrite (8 Process.sleep calls!)

**Phase 5: Infrastructure (Medium Risk)**
12. Update `test_helper.exs` - Remove global Process.sleep
13. Review all tests for edge cases

---

## 4. Implementation Plan

### 4.1 Phase 1: Foundation Updates

#### Task 1.1: Upgrade Isolation Level

**File:** `test/support/test_case.ex`

**Change:**
```diff
defmodule Snakepit.TestCase do
  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
-     use Supertester.UnifiedTestFoundation, isolation: :basic
+     use Supertester.UnifiedTestFoundation, isolation: :full_isolation

      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import Snakepit.TestHelpers
    end
  end
end
```

**Testing:**
```bash
mix test test/unit/bridge/session_store_test.exs  # Simple test to verify
```

**Risk:** Low - Supertester handles isolation internally
**Rollback:** Change back to `:basic` if issues arise

#### Task 1.2: Add TestableGenServer to GRPCWorker

**File:** `lib/snakepit/grpc_worker.ex`

**Change:**
```diff
defmodule Snakepit.GRPCWorker do
  use GenServer
+ use Supertester.TestableGenServer
  require Logger
```

**Testing:**
```elixir
# In test console (iex -S mix test):
{:ok, worker} = setup_isolated_genserver(Snakepit.Test.MockGRPCWorker, "test",
  adapter: Snakepit.TestAdapters.MockGRPCAdapter, port: 60000)
GenServer.call(worker, :__supertester_sync__)  # Should return :ok
GenServer.call(worker, {:__supertester_sync__, return_state: true})  # Should return state
```

**Risk:** Very Low - Only adds handlers, doesn't change existing behavior
**Rollback:** Remove the `use` line

#### Task 1.3: Add assert_eventually Helper

**File:** `test/support/test_helpers.ex`

**Addition:**
```elixir
@doc """
Poll a condition until it's true or timeout.
Replacement for Process.sleep when waiting for eventual consistency.
"""
def assert_eventually(assertion_fn, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 5_000)
  interval = Keyword.get(opts, :interval, 10)

  deadline = System.monotonic_time(:millisecond) + timeout
  poll_until_true(assertion_fn, deadline, interval)
end

defp poll_until_true(assertion_fn, deadline, interval) do
  current_time = System.monotonic_time(:millisecond)

  if current_time >= deadline do
    # One final attempt, let it fail with proper assertion
    assert assertion_fn.(), "Condition did not become true within timeout"
  else
    if assertion_fn.() do
      :ok
    else
      # Wait a bit and try again using receive timeout (NOT Process.sleep)
      receive do
      after
        interval -> :ok
      end
      poll_until_true(assertion_fn, deadline, interval)
    end
  end
end
```

**Testing:**
```elixir
# Should pass
assert_eventually(fn -> 1 == 1 end, timeout: 100)

# Should fail after timeout
assert_eventually(fn -> false end, timeout: 100)
```

**Risk:** Very Low - New helper, doesn't change existing code

### 4.2 Phase 2: Simple Replacements

#### Task 2.1: Fix grpc_worker_test.exs Line 131

**File:** `test/unit/grpc/grpc_worker_test.exs`

**Before:**
```elixir
test "worker performs periodic health checks", %{worker: worker} do
  send(worker, :health_check)

  # Give it time to process
  Process.sleep(50)  # ❌

  # Worker should still be alive
  assert Process.alive?(worker)
end
```

**After:**
```elixir
test "worker performs periodic health checks", %{worker: worker} do
  send(worker, :health_check)

  # Ensure health check message was processed
  :ok = wait_for_genserver_sync(worker, 1_000)  # ✅

  # Worker should still be alive and responsive
  assert Process.alive?(worker)
  assert_genserver_responsive(worker)  # ✅ More explicit
end
```

**Testing:**
```bash
mix test test/unit/grpc/grpc_worker_test.exs:126
```

**Risk:** Very Low - Simple synchronization improvement

#### Task 2.2: Fix grpc_worker_mock_test.exs Line 106

**File:** `test/unit/grpc/grpc_worker_mock_test.exs`

**Before:**
```elixir
# Stop worker
GenServer.stop(worker)

# Give registry time to update
Process.sleep(10)  # ❌

# Should be unregistered
assert Registry.lookup(Snakepit.Pool.Registry, worker_id) == []
```

**After:**
```elixir
# Stop worker
GenServer.stop(worker)

# Poll until registry is updated
assert_eventually(fn ->
  Registry.lookup(Snakepit.Pool.Registry, worker_id) == []
end, timeout: 1_000)  # ✅
```

**Testing:**
```bash
mix test test/unit/grpc/grpc_worker_mock_test.exs:81
```

**Risk:** Very Low - Polling is more reliable than fixed delay

#### Task 2.3: Fix pool_throughput_test.exs Line 26

**File:** `test/performance/pool_throughput_test.exs`

**Before:**
```elixir
{:ok, _pool} = DynamicSupervisor.start_child(pool_sup, ...)

# Let pool initialize
Process.sleep(100)  # ❌
```

**After:**
```elixir
{:ok, pool_pid} = DynamicSupervisor.start_child(pool_sup, ...)

# Wait for pool to be responsive
:ok = wait_for_genserver_sync(pool_name, 5_000)  # ✅
```

**Testing:**
```bash
mix test test/performance/pool_throughput_test.exs --include performance
```

**Risk:** Low - May need to verify pool initialization is complete

### 4.3 Phase 3: Medium Complexity Refactors

#### Task 3.1: Refactor session_store_test.exs

**File:** `test/unit/bridge/session_store_test.exs`

**Current Test:**
```elixir
test "Session expiration" do
  session_id = "expire_#{System.unique_integer([:positive])}"

  {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 0)
  assert session.id == session_id

  assert {:ok, _} = Snakepit.Bridge.SessionStore.get_session(session_id)

  # Wait at least 1 second
  Process.sleep(1100)  # ❌

  Snakepit.Bridge.SessionStore.cleanup_expired_sessions()
  assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
end
```

**Refactored:**
```elixir
test "Session expiration" do
  session_id = "expire_#{System.unique_integer([:positive])}"

  {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 0)
  assert session.id == session_id

  # Session should exist initially
  assert {:ok, _} = Snakepit.Bridge.SessionStore.get_session(session_id)

  # Poll until session is expired (with safety timeout)
  assert_eventually(fn ->
    Snakepit.Bridge.SessionStore.cleanup_expired_sessions()
    match?({:error, :not_found}, Snakepit.Bridge.SessionStore.get_session(session_id))
  end, timeout: 2_000, interval: 50)  # ✅ Poll every 50ms, max 2s
end
```

**Alternative (if SessionStore supports it):**
```elixir
test "Session expiration with explicit time control" do
  session_id = "expire_#{System.unique_integer([:positive])}"

  # Create session that expires in 1 second
  {:ok, session} = Snakepit.Bridge.SessionStore.create_session(session_id, ttl: 1)

  # Wait for expiration using monotonic time
  expiry_time = :erlang.monotonic_time(:second) + 1

  # Busy-wait until time has passed (no sleep, just receive with timeout)
  wait_until_time(expiry_time)

  # Now cleanup should remove it
  Snakepit.Bridge.SessionStore.cleanup_expired_sessions()
  assert {:error, :not_found} = Snakepit.Bridge.SessionStore.get_session(session_id)
end

defp wait_until_time(target_time) do
  current = :erlang.monotonic_time(:second)
  if current >= target_time do
    :ok
  else
    remaining_ms = (target_time - current) * 1000
    receive do
    after
      remaining_ms -> :ok
    end
  end
end
```

**Testing:**
```bash
mix test test/unit/bridge/session_store_test.exs:32
```

**Risk:** Low-Medium - Need to ensure polling doesn't overwhelm SessionStore

#### Task 3.2: Refactor test_helpers.ex

**File:** `test/support/test_helpers.ex`

**Remove Custom Implementation:**
```diff
- @doc """
- Monitor a GenServer and assert it restarts within timeout.
- """
- def assert_process_restarted(monitor_ref, original_pid, timeout \\ 5_000) do
-   assert_receive {:DOWN, ^monitor_ref, :process, ^original_pid, _reason}, timeout
-   # Give supervisor time to restart
-   Process.sleep(100)
-   # Process should be registered again
-   assert Process.whereis(original_pid) != nil
- end
```

**Update Callers to Use Supertester:**
```elixir
# Instead of:
# ref = Process.monitor(worker)
# assert_process_restarted(ref, worker, 5_000)

# Use:
original_pid = worker
{:ok, new_pid} = wait_for_process_restart(WorkerName, original_pid, 5_000)
assert new_pid != original_pid
```

**Risk:** Medium - Need to identify all callers of this function

### 4.4 Phase 4: Complex Refactors

#### Task 4.1: Complete Rewrite of worker_lifecycle_test.exs

**File:** `test/snakepit/pool/worker_lifecycle_test.exs`

This file has **8 Process.sleep calls** and needs a comprehensive rewrite.

**Current Approach:**
1. Start application
2. Sleep 500ms hoping workers start
3. Count processes
4. Sleep 3000ms hoping shutdown completes
5. Count processes again

**Problems:**
- Timing assumptions may fail on slow CI
- No verification of actual worker state
- No use of OTP synchronization

**Proposed Rewrite:**

```elixir
defmodule Snakepit.Pool.WorkerLifecycleTest do
  @moduledoc """
  Tests that verify worker processes are properly cleaned up using
  Supertester patterns for deterministic synchronization.
  """
  use Snakepit.TestCase, async: false  # Keep async: false - tests application lifecycle

  alias Snakepit.Pool.ProcessRegistry

  setup do
    # Start with clean slate - kill any orphaned processes
    System.cmd("pkill", ["-9", "-f", "grpc_server.py"], stderr_to_stdout: true)

    # Don't sleep - use synchronization
    # The next test will verify workers aren't present
    :ok
  end

  describe "worker cleanup on normal shutdown" do
    test "workers clean up Python processes on normal shutdown" do
      # Start the application
      {:ok, _} = Application.ensure_all_started(:snakepit)
      beam_run_id = ProcessRegistry.get_beam_run_id()

      # Wait for workers to be actually ready (not just started)
      # Assumption: Pool starts at least 2 workers
      assert_eventually(fn ->
        count = count_python_processes(beam_run_id)
        count >= 2
      end, timeout: 10_000, interval: 100)

      python_processes_before = count_python_processes(beam_run_id)
      assert python_processes_before >= 2,
        "Expected at least 2 Python workers, got #{python_processes_before}"

      # Stop the application - this should trigger graceful shutdown
      Application.stop(:snakepit)

      # Wait for all Python processes to exit (poll, don't sleep)
      assert_eventually(fn ->
        count_python_processes(beam_run_id) == 0
      end, timeout: 5_000, interval: 100)

      python_processes_after = count_python_processes(beam_run_id)

      assert python_processes_after == 0,
        """
        Expected 0 Python processes after shutdown, but found #{python_processes_after}.
        Workers started: #{python_processes_before}
        Workers remaining: #{python_processes_after}

        This indicates GRPCWorker.terminate/2 failed to kill Python processes.
        """
    end
  end

  describe "no processes killed during normal operation" do
    test "ApplicationCleanup does NOT run during normal operation" do
      {:ok, _} = Application.ensure_all_started(:snakepit)
      beam_run_id = ProcessRegistry.get_beam_run_id()

      # Wait for workers to start
      assert_eventually(fn ->
        count_python_processes(beam_run_id) >= 2
      end, timeout: 10_000)

      initial_count = count_python_processes(beam_run_id)

      # Monitor process count over time - should remain stable
      # Take samples every 200ms for 2 seconds
      samples =
        for _i <- 1..10 do
          # Use receive timeout instead of Process.sleep
          receive do after 200 -> :ok end
          count_python_processes(beam_run_id)
        end

      # All samples should equal initial count
      stable = Enum.all?(samples, fn count -> count == initial_count end)

      assert stable,
        """
        Python process count changed during normal operation!
        Initial: #{initial_count}, Samples: #{inspect(samples)}

        ApplicationCleanup may be incorrectly killing processes during normal operation.
        """

      Application.stop(:snakepit)

      # Wait for cleanup
      assert_eventually(fn ->
        count_python_processes(beam_run_id) == 0
      end, timeout: 5_000)
    end
  end

  describe "multiple start/stop cycles" do
    test "no orphaned processes exist after multiple cycles" do
      for cycle <- 1..3 do
        {:ok, _} = Application.ensure_all_started(:snakepit)
        beam_run_id = ProcessRegistry.get_beam_run_id()

        # Wait for workers to start
        assert_eventually(fn ->
          count_python_processes(beam_run_id) >= 2
        end, timeout: 10_000)

        # Stop application
        Application.stop(:snakepit)

        # Wait for all processes to exit
        assert_eventually(fn ->
          count_python_processes(beam_run_id) == 0
        end, timeout: 5_000)

        # Check for orphans from this run
        orphans = find_orphaned_processes(beam_run_id)

        if length(orphans) > 0 do
          # Cleanup before failing
          System.cmd("pkill", ["-9", "-f", "grpc_server.py"], stderr_to_stdout: true)

          flunk("""
          Cycle #{cycle}: Found #{length(orphans)} orphaned processes!
          BEAM run ID: #{beam_run_id}
          Orphaned PIDs: #{inspect(orphans)}
          """)
        end
      end
    end
  end

  # Helper functions (unchanged)
  defp count_python_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true) do
      {"", 1} -> 0
      {output, 0} -> output |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  defp find_orphaned_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true) do
      {"", 1} -> []
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn pid_str ->
          case Integer.parse(pid_str) do
            {pid, ""} -> pid
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end
end
```

**Key Changes:**
1. ✅ Removed all 8 Process.sleep calls
2. ✅ Added `assert_eventually` for polling
3. ✅ More explicit about what we're waiting for
4. ✅ Better error messages
5. ✅ Sampling approach for stability test (more rigorous)

**Testing:**
```bash
mix test test/snakepit/pool/worker_lifecycle_test.exs
```

**Risk:** Medium-High
- Complex test with system-level interactions
- Timing may still be an issue on very slow systems
- Need to verify graceful shutdown logic works correctly

**Mitigation:**
- Increase timeouts if needed (10s is reasonable for CI)
- Add detailed logging for debugging
- Test on both fast and slow machines

#### Task 4.2: Rewrite application_cleanup_test.exs

**File:** `test/snakepit/pool/application_cleanup_test.exs`

**Proposed Rewrite:**

```elixir
defmodule Snakepit.Pool.ApplicationCleanupTest do
  @moduledoc """
  Tests that verify ApplicationCleanup does not kill processes during normal operation.
  Uses Supertester patterns for deterministic verification.
  """
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool.ProcessRegistry

  test "ApplicationCleanup does NOT kill processes from current BEAM run" do
    # Start app
    {:ok, _} = Application.ensure_all_started(:snakepit)
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Wait for workers to fully start
    assert_eventually(fn ->
      count_python_processes(beam_run_id) >= 2
    end, timeout: 10_000)

    # Get initial count
    initial_count = count_python_processes(beam_run_id)
    assert initial_count >= 2, "Expected at least 2 workers to start"

    # Monitor for stability over 2 seconds
    # Take 20 samples at 100ms intervals
    stable = monitor_process_stability(beam_run_id, initial_count, samples: 20, interval: 100)

    assert stable,
      """
      ApplicationCleanup killed processes from current run!
      This is the bug causing "Python gRPC server process exited with status 0" errors.
      ApplicationCleanup.terminate must ONLY kill processes from DIFFERENT beam_run_ids!
      """

    # Cleanup
    Application.stop(:snakepit)

    # Verify all processes are cleaned up
    assert_eventually(fn ->
      count_python_processes(beam_run_id) == 0
    end, timeout: 5_000)
  end

  # Helper to monitor process count stability
  defp monitor_process_stability(beam_run_id, expected_count, opts) do
    samples = Keyword.get(opts, :samples, 10)
    interval = Keyword.get(opts, :interval, 100)

    results =
      for _i <- 1..samples do
        # Use receive timeout instead of Process.sleep
        receive do after interval -> :ok end
        count = count_python_processes(beam_run_id)
        {count, count == expected_count}
      end

    # All samples should match expected count
    all_stable = Enum.all?(results, fn {_count, stable} -> stable end)

    unless all_stable do
      counts = Enum.map(results, fn {count, _} -> count end)
      IO.puts("Process count over time: #{inspect(counts)} (expected: #{expected_count})")
    end

    all_stable
  end

  defp count_python_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true) do
      {"", 1} -> 0
      {output, 0} -> output |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end
end
```

**Key Changes:**
1. ✅ Removed all 3 Process.sleep calls
2. ✅ Added proper polling with `assert_eventually`
3. ✅ More rigorous stability monitoring (20 samples)
4. ✅ Better diagnostic output

**Testing:**
```bash
mix test test/snakepit/pool/application_cleanup_test.exs
```

**Risk:** Medium
- Tests application-wide behavior
- Depends on external Python processes
- Timing may vary

### 4.5 Phase 5: Infrastructure Updates

#### Task 5.1: Update test_helper.exs

**File:** `test/test_helper.exs`

**Before:**
```elixir
ExUnit.after_suite(fn _ ->
  # Stop the application
  Application.stop(:snakepit)

  # Give workers time to shut down gracefully
  Process.sleep(2000)  # ❌

  :ok
end)
```

**After:**
```elixir
ExUnit.after_suite(fn _ ->
  # Stop the application
  Application.stop(:snakepit)

  # Poll until all workers are shut down
  beam_run_id = Snakepit.Pool.ProcessRegistry.get_beam_run_id()

  deadline = System.monotonic_time(:millisecond) + 5_000
  wait_for_worker_shutdown(beam_run_id, deadline)

  :ok
end)

defp wait_for_worker_shutdown(beam_run_id, deadline) do
  current = System.monotonic_time(:millisecond)

  if current >= deadline do
    # Timeout - log warning but don't fail
    IO.puts(:stderr, "Warning: Workers did not shut down within timeout")
    :ok
  else
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true) do
      {"", 1} ->
        # All workers shut down
        :ok

      _ ->
        # Still workers running, wait and check again
        receive do after 100 -> :ok end
        wait_for_worker_shutdown(beam_run_id, deadline)
    end
  end
end
```

**Risk:** Low-Medium
- Global test infrastructure change
- Affects all test runs

---

## 5. Risk Assessment

### 5.1 Overall Risk Matrix

| Phase | Task | Risk Level | Mitigation |
|-------|------|------------|------------|
| 1.1 | Upgrade isolation | Low | Easy rollback |
| 1.2 | Add TestableGenServer | Very Low | Only adds handlers |
| 1.3 | Add assert_eventually | Very Low | New helper |
| 2.1-2.3 | Simple sleep replacements | Very Low | One-line changes |
| 3.1 | Session expiration | Low-Medium | Careful polling |
| 3.2 | Remove custom helpers | Medium | Find all callers |
| 4.1 | worker_lifecycle rewrite | Medium-High | Complex interactions |
| 4.2 | application_cleanup rewrite | Medium | System-level testing |
| 5.1 | test_helper update | Low-Medium | Global change |

### 5.2 Risk Mitigation Strategies

1. **Incremental Changes**: One file at a time, commit after each successful change
2. **Comprehensive Testing**: Run full test suite after each phase
3. **Rollback Plan**: Keep original code in comments temporarily
4. **CI Monitoring**: Watch for flakiness in CI environment
5. **Timeout Tuning**: Be generous with timeouts initially, optimize later

### 5.3 Testing Strategy for Each Change

```bash
# After each file change:
mix test path/to/changed_test.exs          # Run affected tests

# After each phase:
mix test                                    # Run full suite

# Before merging:
mix test --repeat 10                        # Check for flakiness
mix test --trace                            # Detailed output
mix test --slowest 10                       # Identify slow tests
```

---

## 6. Low-Risk Improvements

Beyond Supertester conformance, here are additional low-risk improvements:

### 6.1 Add Documentation to Tests

**Current:** Many tests lack clear documentation

**Improvement:**
```elixir
# ❌ Current
test "worker handles ping command", %{worker: worker} do
  {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000})
  assert result["status"] == "pong"
end

# ✅ Improved
@tag :unit
@tag :grpc_worker
test "worker handles ping command and returns pong status", %{worker: worker} do
  # When: We send a ping command to the worker
  {:ok, result} = GenServer.call(worker, {:execute, "ping", %{}, 5_000})

  # Then: Worker should respond with pong status
  assert result["status"] == "pong"
  assert result["worker_id"] == "test_worker"
end
```

**Benefit:** Better test readability and documentation

### 6.2 Add Test Tags for Organization

**Current:** Limited use of test tags

**Improvement:**
```elixir
# In test files:
@moduletag :integration       # For integration tests
@moduletag :performance       # For performance tests
@moduletag :python_required   # For tests requiring Python

# In individual tests:
@tag :slow                    # For tests that take >1s
@tag :external_dependency     # For tests with external deps
@tag timeout: 60_000          # For tests needing longer timeouts
```

**Usage:**
```bash
mix test --exclude slow                    # Skip slow tests in dev
mix test --only integration                # Run only integration tests
mix test --exclude external_dependency     # Skip tests needing external services
```

**Benefit:** Better test organization and selective running

### 6.3 Improve Error Messages

**Current:** Generic assertion failures

**Improvement:**
```elixir
# ❌ Current
assert stats.requests == 5

# ✅ Improved
assert stats.requests == 5,
  "Expected 5 requests but got #{stats.requests}. Stats: #{inspect(stats)}"
```

**Benefit:** Faster debugging when tests fail

### 6.4 Add Property-Based Tests

**Current:** No property-based tests

**Proposed:** Add StreamData for critical functions

```elixir
use ExUnitProperties

property "worker handles arbitrary valid commands" do
  check all command <- member_of(["ping", "echo", "health"]),
            args <- map_of(string(:alphanumeric), string(:alphanumeric)),
            max_runs: 100 do

    {:ok, worker} = setup_isolated_genserver(MockGRPCWorker, "property_test")

    case GenServer.call(worker, {:execute, command, args, 5_000}) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok  # Either outcome is acceptable
    end
  end
end
```

**Benefit:** Better coverage of edge cases

### 6.5 Add Shared Setup with ExUnit.CaseTemplate

**Current:** Duplicated setup code across tests

**Improvement:**
```elixir
# test/support/grpc_worker_case.ex
defmodule Snakepit.GRPCWorkerCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Snakepit.TestHelpers
      import Supertester.{OTPHelpers, GenServerHelpers, Assertions}

      setup context do
        # Common setup for all gRPC worker tests
        test_name = to_string(context.test)

        {:ok, worker} = setup_isolated_genserver(
          Snakepit.Test.MockGRPCWorker,
          test_name,
          adapter: Snakepit.TestAdapters.MockGRPCAdapter
        )

        :ok = wait_for_genserver_sync(worker, 5_000)

        %{worker: worker, test_name: test_name}
      end
    end
  end
end

# Usage in tests:
defmodule Snakepit.GRPCWorker.SomeTest do
  use Snakepit.GRPCWorkerCase  # ✅ Common setup automatically applied

  test "some specific test", %{worker: worker} do
    # worker is already set up and ready
  end
end
```

**Benefit:** DRY principle, consistent setup

### 6.6 Add Test Utilities Module

**File:** `test/support/test_utilities.ex`

```elixir
defmodule Snakepit.TestUtilities do
  @moduledoc """
  Shared test utilities and helpers.
  """

  @doc """
  Create a test session ID with optional prefix.
  """
  def test_session_id(prefix \\ "test") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  @doc """
  Generate test data for gRPC commands.
  """
  def test_grpc_args(overrides \\ %{}) do
    Map.merge(%{
      "test" => true,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }, overrides)
  end

  @doc """
  Capture and filter log output during test.
  """
  def with_log_capture(level \\ :info, fun) do
    ExUnit.CaptureLog.capture_log([level: level], fun)
  end
end
```

**Benefit:** Shared utilities reduce duplication

---

## 7. Testing the Refactor

### 7.1 Pre-Refactor Baseline

Before starting, establish baseline:

```bash
# Run tests 10 times to check for flakiness
./scripts/test_baseline.sh

# Content of scripts/test_baseline.sh:
#!/bin/bash
echo "Running baseline test suite 10 times..."
FAILURES=0
for i in {1..10}; do
  echo "Run $i/10..."
  mix test --seed 0 > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
  fi
done
echo "Failures: $FAILURES/10"
```

**Record:**
- Total test count
- Average runtime
- Flaky tests (failures/10 runs)
- Slowest tests

### 7.2 During Refactor

After each phase:

```bash
# Quick validation
mix test path/to/changed_file.exs

# Full suite
mix test

# Check for new flakiness
mix test --seed 0 --repeat 3
```

### 7.3 Post-Refactor Validation

```bash
# Full validation suite
./scripts/validate_refactor.sh

# Content of scripts/validate_refactor.sh:
#!/bin/bash
set -e

echo "=== Validation Suite ==="

echo "1. Full test suite..."
mix test

echo "2. Checking for Process.sleep in tests..."
SLEEPS=$(grep -r "Process\.sleep" test/ --exclude-dir=deps || true)
if [ -n "$SLEEPS" ]; then
  echo "⚠️  Found Process.sleep in tests:"
  echo "$SLEEPS"
else
  echo "✅ No Process.sleep found in tests"
fi

echo "3. Running tests 10 times for flakiness check..."
FAILURES=0
for i in {1..10}; do
  mix test --seed $i > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
  fi
done
echo "Flakiness: $FAILURES/10 failures"

echo "4. Performance check..."
mix test --slowest 10

echo "5. Coverage check..."
mix test --cover

echo "=== Validation Complete ==="
```

### 7.4 Success Criteria

✅ **Must Have:**
- All tests pass
- Zero Process.sleep in test code (except mock adapters)
- No new flaky tests
- CI passes on all platforms

✅ **Should Have:**
- Test suite runs 10-20% faster (no arbitrary waits)
- Better error messages
- Improved test documentation

✅ **Nice to Have:**
- Test coverage maintained or improved
- All tests use `async: true` where possible

---

## 8. Rollout Plan

### 8.1 Development Timeline

**Week 1: Foundation (Low Risk)**
- Day 1: Update isolation level, add TestableGenServer
- Day 2: Add assert_eventually helper
- Day 3: Phase 2 simple replacements
- Day 4: Testing and validation
- Day 5: Buffer for issues

**Week 2: Medium Complexity (Medium Risk)**
- Day 1-2: Refactor session_store_test, test_helpers
- Day 3: Refactor python_integration_test
- Day 4-5: Testing and validation

**Week 3: Complex Refactors (Higher Risk)**
- Day 1-2: Rewrite worker_lifecycle_test
- Day 3: Rewrite application_cleanup_test
- Day 4: Update test_helper.exs
- Day 5: Full validation

**Week 4: Polish and Documentation**
- Day 1-2: Add low-risk improvements
- Day 3: Update documentation
- Day 4: Final testing
- Day 5: Review and merge

### 8.2 Git Strategy

**Branch Structure:**
```
main
└── refactor/supertester-conformance
    ├── refactor/phase-1-foundation
    ├── refactor/phase-2-simple
    ├── refactor/phase-3-medium
    ├── refactor/phase-4-complex
    └── refactor/phase-5-infrastructure
```

**Commit Strategy:**
- One commit per task
- Descriptive commit messages
- Include before/after in commit message

**Example Commit:**
```
refactor(tests): Replace Process.sleep with wait_for_genserver_sync in grpc_worker_test

Before:
  send(worker, :health_check)
  Process.sleep(50)
  assert Process.alive?(worker)

After:
  send(worker, :health_check)
  :ok = wait_for_genserver_sync(worker, 1_000)
  assert_genserver_responsive(worker)

- Removes timing assumption
- More deterministic
- Supertester conformant

Test: mix test test/unit/grpc/grpc_worker_test.exs:126
```

### 8.3 Review Process

**Phase 1-2:** Self-review + automated tests
**Phase 3-4:** Peer review required
**Phase 5:** Team review + sign-off

### 8.4 Rollback Plan

If issues arise:

1. **Individual Task Rollback:**
   ```bash
   git revert <commit-hash>
   ```

2. **Phase Rollback:**
   ```bash
   git reset --hard refactor/phase-N-1
   ```

3. **Complete Rollback:**
   ```bash
   git checkout main
   ```

**Rollback Triggers:**
- Test suite failure rate >5%
- New flaky tests introduced
- Performance degradation >20%
- CI failures on any platform

---

## 9. Appendix

### 9.1 Supertester Quick Reference

**Common Patterns:**

```elixir
# 1. Setup isolated GenServer
{:ok, server} = setup_isolated_genserver(MyServer, "test_name")

# 2. Wait for GenServer sync
:ok = wait_for_genserver_sync(server, timeout)

# 3. Cast and sync pattern
:ok = cast_and_sync(server, :increment)

# 4. Get server state safely
{:ok, state} = get_server_state_safely(server)

# 5. Assert on state
assert_genserver_state(server, fn state -> state.count > 0 end)

# 6. Wait for process restart
{:ok, new_pid} = wait_for_process_restart(ServerName, old_pid, timeout)

# 7. Setup isolated supervisor
{:ok, supervisor} = setup_isolated_supervisor(MySupervisor, "test_name")

# 8. Wait for supervisor stabilization
:ok = wait_for_supervisor_stabilization(supervisor, timeout)

# 9. Assert all children alive
assert_all_children_alive(supervisor)

# 10. Assert process alive
assert_process_alive(pid)
```

### 9.2 Anti-Patterns to Avoid

❌ **DON'T:**
```elixir
# 1. Using Process.sleep for synchronization
Process.sleep(100)

# 2. Manual cleanup without on_exit
GenServer.stop(server)

# 3. Raw :sys.get_state without error handling
state = :sys.get_state(server)

# 4. Assuming timing
assert something_happened  # After async operation

# 5. Using async: false unnecessarily
use ExUnit.Case, async: false
```

✅ **DO:**
```elixir
# 1. Use wait_for_genserver_sync
:ok = wait_for_genserver_sync(server, timeout)

# 2. Use setup_isolated_genserver (handles cleanup)
{:ok, server} = setup_isolated_genserver(MyServer, "test")

# 3. Use get_server_state_safely
{:ok, state} = get_server_state_safely(server)

# 4. Use cast_and_sync for async operations
:ok = cast_and_sync(server, :async_operation)
assert_genserver_state(server, fn s -> s.done == true end)

# 5. Use async: true with proper isolation
use Snakepit.TestCase  # Default async: true
```

### 9.3 Useful Resources

**Supertester Documentation:**
- `/home/home/p/g/n/supertester/README.md` - Overview
- `/home/home/p/g/n/supertester/MANUAL.md` - Complete reference
- `/home/home/p/g/n/supertester/docs/` - Detailed docs

**Elixir Testing:**
- [ExUnit documentation](https://hexdocs.pm/ex_unit/)
- [Testing OTP Applications](https://hexdocs.pm/elixir/testing.html)

**Best Practices:**
- [Elixir Testing Guide](https://github.com/dwyl/learn-elixir)

---

## 10. Conclusion

This refactoring plan provides a comprehensive, incremental approach to achieving full Supertester conformance while improving overall test quality. By following this plan:

1. ✅ We eliminate all timing-based synchronization
2. ✅ We adopt industry best practices for OTP testing
3. ✅ We improve test reliability and determinism
4. ✅ We reduce test suite flakiness
5. ✅ We create a more maintainable test codebase

**Next Steps:**
1. Review and approve this plan
2. Create GitHub issues for each phase
3. Begin Phase 1 implementation
4. Monitor progress and adjust as needed

**Success Metrics:**
- Zero Process.sleep in test code
- 100% Supertester helper adoption
- <2% test failure rate in CI
- Improved developer experience

---

**Document Status:** Ready for Review
**Last Updated:** 2025-10-10
**Version:** 1.0
