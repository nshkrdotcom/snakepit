# TDD Roadmap - Driven by Actual Test Failures

**Date**: 2025-10-11
**Baseline**: 68 total tests, 62 passing, 6 failing in new tests
**Approach**: Fix failures one by one, test-driven

---

## Test Baseline Status

### ✅ Passing Tests (62/68)
- Unit tests: config, python_version, compatibility (55 tests)
- Integration tests: backward compat, profile basics (7 tests)

### ❌ Failing Tests (6/68 - These Drive Implementation)

1. **Multi-pool startup** (multi_pool_execution_test.exs:11)
   - Starts 2 pools, executes on both
   - **Fails**: Only uses first pool, can't distinguish pool_a vs pool_b

2. **Multi-pool worker isolation** (multi_pool_execution_test.exs:60)
   - Verifies pools have independent workers
   - **Fails**: list_workers() doesn't support named pools

3. **Pool routing** (multi_pool_execution_test.exs:115)
   - Execute on :named_pool specifically
   - **Fails**: execute() doesn't accept pool_name parameter

4. **Thread profile startup with Python 3.13** (thread_profile_python313_test.exs:40)
   - Starts thread worker, executes request
   - **Fails**: Thread profile workers start but threaded server may not be selected

5. **Thread capacity > 1** (thread_profile_python313_test.exs:68)
   - Verifies thread worker has capacity matching threads_per_worker
   - **Partially works** but needs verification

6. **Concurrent requests on thread worker** (thread_profile_python313_test.exs:99)
   - 4 concurrent requests on 1 worker with 4 threads
   - **Fails**: Need to verify concurrent execution

7. **Python 3.13 detection** (thread_profile_python313_test.exs:177-193)
   - Detects Python 3.13, recommends thread profile
   - **May pass** with Python 3.13 configured

---

## Implementation Roadmap (Priority Order)

### Milestone 1: Multi-Pool Fundamentals (4-6 hours)

#### Task 1.1: Multi-Pool State in Pool.ex
**File**: `lib/snakepit/pool/pool.ex`
**Changes**:
```elixir
defstruct [
  :pools,  # NEW: %{pool_name => pool_state}
  # Remove single-pool fields or keep for backward compat
]

def init(opts) do
  {:ok, pool_configs} = Snakepit.Config.get_pool_configs()

  # For each pool config, initialize pool state
  pools = Enum.into(pool_configs, %{}, fn config ->
    {config.name, %{
      workers: [],
      available: MapSet.new(),
      busy: %{},
      request_queue: :queue.new(),
      config: config
    }}
  end)

  state = %__MODULE__{pools: pools}
  {:ok, state, {:continue, :initialize_all_pools}}
end
```

**Test that will pass**: `multi_pool_execution_test.exs:11-48` (startup test)

#### Task 1.2: Pool Routing - execute/4 with pool_name
**File**: `lib/snakepit.ex`
**Changes**:
```elixir
# Old: execute(command, args, opts)
# New: execute(pool_name \\ :default, command, args, opts)

def execute(pool_name, command, args, opts \\ []) when is_atom(pool_name) do
  Snakepit.Pool.execute(pool_name, command, args, opts)
end

def execute(command, args, opts) when is_binary(command) do
  # Backward compat: no pool_name means :default
  Snakepit.Pool.execute(:default, command, args, opts)
end
```

**File**: `lib/snakepit/pool/pool.ex`
**Changes**:
```elixir
def handle_call({:execute, pool_name, command, args, opts}, from, state) do
  pool_state = Map.get(state.pools, pool_name)

  case checkout_worker(pool_state) do
    {:ok, worker_id, new_pool_state} ->
      # Execute...
      # Update state.pools[pool_name]
  end
end
```

**Test that will pass**: `multi_pool_execution_test.exs:115-128` (routing test)

#### Task 1.3: Per-Pool Worker Tracking
**File**: `lib/snakepit/pool/pool.ex`
**Changes**:
```elixir
def list_workers(pool_name \\ :default) do
  GenServer.call(__MODULE__, {:list_workers, pool_name})
end

def handle_call({:list_workers, pool_name}, _from, state) do
  pool_state = Map.get(state.pools, pool_name, %{})
  {:reply, Map.get(pool_state, :workers, []), state}
end
```

**Test that will pass**: `multi_pool_execution_test.exs:60-82` (isolation test)

---

### Milestone 2: Thread Profile with Python 3.13 (2-3 hours)

#### Task 2.1: Ensure Threaded Script Selection
**File**: `lib/snakepit/adapters/grpc_python.ex`
**Current**: Already checks for `--max-workers` flag
**Verify**: Thread profile config includes `--max-workers`
**Test**: Start thread pool, verify grpc_server_threaded.py used

**Test that will pass**: `thread_profile_python313_test.exs:40-60` (startup test)

#### Task 2.2: Verify Thread Capacity Tracking
**File**: `lib/snakepit/worker_profile/thread.ex`
**Current**: ETS tracking implemented
**Verify**: get_capacity returns threads_per_worker
**Test**: Start thread worker, check capacity

**Test that will pass**: `thread_profile_python313_test.exs:68-90` (capacity test)

#### Task 2.3: Concurrent Request Handling
**File**: `lib/snakepit/worker_profile/thread.ex`
**Current**: check_and_increment_load() implemented
**Verify**: Multiple concurrent requests to same worker work
**Test**: Send 4 concurrent requests to 1 worker with capacity 4

**Test that will pass**: `thread_profile_python313_test.exs:99-133` (concurrency test)

---

### Milestone 3: Python Version Detection with 3.13 (1 hour)

#### Task 3.1: Python 3.13 Environment in Tests
**File**: `test/support/python_env.ex`
**Current**: Helper exists
**Needed**: Actually use it in tests
**Test**: Configure SNAKEPIT_PYTHON=.venv-py313, detect version

**Test that will pass**: `thread_profile_python313_test.exs:177-193` (detection tests)

---

## Execution Plan

### Step 1: Run Current Tests, Document Failures
```bash
SNAKEPIT_PYTHON=.venv-py313/bin/python3 mix test test/snakepit/thread_profile_python313_test.exs test/snakepit/multi_pool_execution_test.exs

# Expected: 13 tests, 7 failures
# Document which ones fail and why
```

### Step 2: Implement Milestone 1 (Multi-Pool)
```bash
# Implement Task 1.1 (multi-pool state)
mix test test/snakepit/multi_pool_execution_test.exs:11
# Should pass after implementation

# Implement Task 1.2 (routing)
mix test test/snakepit/multi_pool_execution_test.exs:115
# Should pass

# Implement Task 1.3 (per-pool workers)
mix test test/snakepit/multi_pool_execution_test.exs:60
# Should pass
```

### Step 3: Implement Milestone 2 (Thread Profile)
```bash
# Tasks 2.1-2.3 (thread execution)
SNAKEPIT_PYTHON=.venv-py313/bin/python3 mix test test/snakepit/thread_profile_python313_test.exs
# Should go from 5 failures to 0
```

### Step 4: Full Test Suite
```bash
mix test
# All 68+ tests should pass
```

---

## Current Test Count

### By Category
- **Unit tests**: 55 (all passing)
- **Integration tests**: 11 (all passing)
- **Multi-pool tests**: 7 (4 failing, 3 skipped)
- **Thread profile tests**: 6 (5 failing, 1 may pass)
- **Total**: 79 tests

### By Status
- ✅ Passing: 62 (78%)
- ❌ Failing: 7 (9%) - **These are our TDD targets**
- ⏭️ Skipped: 10 (13%) - **Long-running or future**

---

## What Failures Tell Us

### Failure Group 1: Multi-Pool Not Wired (3 failures)
- Pool.init uses first pool only
- No pool routing in execute
- No per-pool worker tracking

**Fix**: Refactor Pool state to `%{pools: map}`

### Failure Group 2: Thread Profile Untested (4 failures)
- Thread workers may start but not with threaded server
- Capacity tracking needs verification
- Concurrent execution needs validation

**Fix**: Ensure thread profile config correct, verify with Python 3.13

### Failure Group 3: Python 3.13 Detection (2 failures may now pass)
- Need to verify with actual Python 3.13
- May already work with .venv-py313

**Fix**: Configure test to use Python 3.13 path

---

## Success Criteria

### For v0.6.0 Release:
- ✅ All 55 unit tests pass
- ✅ All 11 integration tests pass
- ✅ Multi-pool tests pass (7 tests)
- ✅ Thread profile tests pass with Python 3.13 (6 tests)
- ✅ Total: 79 tests, 0 failures

### Estimated Effort:
- Milestone 1 (Multi-pool): 4-6 hours
- Milestone 2 (Thread): 2-3 hours
- Milestone 3 (Detection): 1 hour
- **Total**: 7-10 hours of focused TDD

---

## Next Action

Run this command and paste output:
```bash
SNAKEPIT_PYTHON=.venv-py313/bin/python3 mix test test/snakepit/thread_profile_python313_test.exs:177 --trace
```

This will show if Python 3.13 detection tests pass with the configured environment.

Then we systematically fix each failure, one test at a time.
