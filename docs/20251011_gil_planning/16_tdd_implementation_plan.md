# TDD Implementation Plan - Multi-Pool Integration

**Date**: 2025-10-11
**Approach**: Test-Driven Development
**Goal**: Fully integrate multi-pool + WorkerProfile architecture

---

## Current State

### What Works ✅
- Config system validates multi-pool configs
- WorkerProfile behaviour defined
- ProcessProfile implementation complete
- ThreadProfile implementation complete
- LifecycleManager exists

### What's Missing ❌
- **Pool doesn't use WorkerProfile** - Still calls WorkerSupervisor directly
- **Pool doesn't support multi-pool** - Assumes single pool from v0.5.x
- **No pool routing** - Can't execute on named pools
- **WorkerProfile not actually invoked** - Profiles exist but unused

---

## Integration Tests Written (Will Fail)

### 1. `test/snakepit/integration/multi_pool_test.exs`
**Tests:**
- Start multiple pools with different profiles
- Route requests to correct pool by name
- Pools have independent worker sets
- Different recycling policies per pool
- WorkerProfile abstraction actually used
- Backward compatibility with legacy config

**Status**: 🔴 Will fail (Pool doesn't support multi-pool yet)

### 2. `test/snakepit/integration/lifecycle_integration_test.exs`
**Tests:**
- TTL recycling actually recycles workers
- Request-count recycling works
- Different TTLs per pool
- Telemetry events emitted
- Zero-downtime replacement

**Status**: 🔴 Will fail (LifecycleManager not wired to Pool)

### 3. `test/snakepit/integration/profile_execution_test.exs`
**Tests:**
- Process profile executes (backward compat)
- Thread profile executes (Python 3.13+)
- Concurrent requests on thread profile
- Capacity limits enforced
- Environment variables correct per profile
- Metadata accurate

**Status**: 🔴 Will fail (profiles not actually used)

---

## Implementation Dependency Graph

```
Level 0: Foundation (EXISTS)
  ├─ Config.get_pool_configs/0
  ├─ WorkerProfile behaviour
  ├─ ProcessProfile
  ├─ ThreadProfile
  └─ LifecycleManager

Level 1: Pool Multi-Pool Support (NEEDED)
  ├─ Pool.init/1 - Accept :pools option
  ├─ Pool state - Track multiple pools
  ├─ Pool.start_workers - Per-pool initialization
  └─ Pool.list_pools/0

Level 2: Pool Routing (NEEDED)
  ├─ Pool.execute - Accept pool_name parameter
  ├─ Pool.get_stats - Per-pool stats
  ├─ Pool.list_workers - Per-pool workers
  └─ Pool routing logic

Level 3: WorkerProfile Integration (NEEDED)
  ├─ Pool uses profile_module.start_worker/1
  ├─ Profile-specific config passed to workers
  ├─ Environment variables from profile
  └─ Adapter args from profile

Level 4: Lifecycle Integration (NEEDED)
  ├─ Workers register with LifecycleManager
  ├─ Request counting hooked up
  ├─ Recycling triggers replacement
  └─ Per-pool lifecycle policies

Level 5: Validation (TESTS PASS)
  ├─ Multi-pool tests pass
  ├─ Lifecycle tests pass
  ├─ Profile tests pass
  └─ Backward compat verified
```

---

## Implementation Order (TDD)

### Step 1: Config Integration (Make backward compat test pass)
**File**: `lib/snakepit/pool/pool.ex`
**Change**: Pool.init/1 reads from Config.get_pool_configs/0

**Test that will pass**:
```elixir
test "legacy single-pool config still works"
```

**Implementation**:
```elixir
def init(opts) do
  # Get pool configs (supports both legacy and new format)
  {:ok, pool_configs} = Snakepit.Config.get_pool_configs()

  # For v0.6.0: Just use first pool (single-pool support)
  [pool_config | _] = pool_configs

  # Rest stays same for now
  state = %__MODULE__{
    size: pool_config.pool_size,
    # ...
  }
end
```

**Validation**: `mix test test/snakepit/integration/multi_pool_test.exs:82`

---

### Step 2: WorkerProfile Integration (Make profile startup test pass)
**File**: `lib/snakepit/pool/pool.ex`
**Change**: Use profile module to start workers

**Test that will pass**:
```elixir
test "Pool uses profile module to start workers"
```

**Implementation**:
```elixir
defp start_workers_concurrently(count, pool_config) do
  profile_module = Config.get_profile_module(pool_config)

  # For each worker
  worker_config = %{
    worker_id: worker_id,
    worker_profile: pool_config.worker_profile,
    threads_per_worker: pool_config[:threads_per_worker],
    adapter_module: pool_config.adapter_module,
    adapter_args: pool_config[:adapter_args],
    adapter_env: pool_config[:adapter_env],
    pool_name: pool_name
  }

  {:ok, pid} = profile_module.start_worker(worker_config)
end
```

**Validation**: `mix test test/snakepit/integration/multi_pool_test.exs:96`

---

### Step 3: Multi-Pool State (Make multi-pool test pass)
**File**: `lib/snakepit/pool/pool.ex`
**Change**: Track multiple pools in state

**Test that will pass**:
```elixir
test "starts multiple pools with different profiles"
test "pools have independent worker sets"
```

**Implementation**:
```elixir
defstruct [
  :pools,  # NEW: %{pool_name => pool_state}
  # Remove single-pool fields
]

def init(opts) do
  {:ok, pool_configs} = Config.get_pool_configs()

  pools = Enum.into(pool_configs, %{}, fn config ->
    {config.name, initialize_pool(config)}
  end)

  state = %__MODULE__{pools: pools}
  {:ok, state}
end
```

**Validation**: `mix test test/snakepit/integration/multi_pool_test.exs:7-40`

---

### Step 4: Pool Routing (Make routing test pass)
**File**: `lib/snakepit/pool/pool.ex`
**Change**: Execute routes to named pool

**Test that will pass**:
```elixir
test "routes requests to correct pool by name"
```

**Implementation**:
```elixir
def execute(pool_name \\ :default, command, args, opts \\ []) do
  GenServer.call(__MODULE__, {:execute, pool_name, command, args, opts})
end

def handle_call({:execute, pool_name, command, args, opts}, from, state) do
  pool_state = Map.get(state.pools, pool_name)

  case checkout_worker(pool_state) do
    {:ok, worker_id, new_pool_state} ->
      # Execute
      # Update pools map
  end
end
```

**Validation**: `mix test test/snakepit/integration/multi_pool_test.exs:42-60`

---

### Step 5: Lifecycle Wiring (Make TTL test pass)
**Files**: `lib/snakepit/grpc_worker.ex`, `lib/snakepit/pool/pool.ex`
**Change**: Workers register with LifecycleManager, pass config

**Test that will pass**:
```elixir
test "worker is recycled after TTL expires"
```

**Implementation**:
```elixir
# In GRPCWorker.handle_continue after registration
Snakepit.Worker.LifecycleManager.track_worker(
  pool_name,
  worker_id,
  self(),
  pool_config  # ← Must include worker_ttl, worker_max_requests
)
```

**Validation**: `mix test test/snakepit/integration/lifecycle_integration_test.exs:9` (long test)

---

### Step 6: Request Counting (Make request recycling test pass)
**File**: `lib/snakepit/pool/pool.ex`
**Change**: Increment count on successful request

**Test that will pass**:
```elixir
test "worker is recycled after max requests"
```

**Implementation**: Already done in Phase 4!
```elixir
defp execute_on_worker(worker_id, command, args, opts) do
  result = worker_module.execute(worker_id, command, args, timeout)

  case result do
    {:ok, _} ->
      Snakepit.Worker.LifecycleManager.increment_request_count(worker_id)
    _ -> :ok
  end

  result
end
```

**Validation**: `mix test test/snakepit/integration/lifecycle_integration_test.exs:47`

---

## Test Run Plan

### Run 1: Baseline (All fail)
```bash
mix test test/snakepit/integration/
# Expected: Many failures
```

### Run 2: After Step 1 (Config integration)
```bash
mix test test/snakepit/integration/multi_pool_test.exs:82
# Expected: Backward compat test passes
```

### Run 3: After Step 2 (WorkerProfile)
```bash
mix test test/snakepit/integration/multi_pool_test.exs:96
# Expected: Profile usage test passes
```

### Run 4: After Step 3 (Multi-pool state)
```bash
mix test test/snakepit/integration/multi_pool_test.exs:7
# Expected: Multi-pool startup passes
```

### Run 5: After Step 4 (Routing)
```bash
mix test test/snakepit/integration/multi_pool_test.exs:42
# Expected: Routing test passes
```

### Run 6: After Steps 5-6 (Lifecycle)
```bash
mix test test/snakepit/integration/lifecycle_integration_test.exs
# Expected: TTL and request-count tests pass
```

### Final Run: All integration tests
```bash
mix test test/snakepit/integration/
# Expected: All pass (except skipped Python 3.13+ tests)
```

---

## Critical Realizations

### 1. Multi-Pool ≠ Multi-Python
- Multi-pool uses **one Python installation**
- Different pools = different **workload strategies**
- GIL vs no-GIL is a **node-wide Python upgrade**, not per-pool

### 2. Thread Profile Testing Limitation
- Cannot truly test without Python 3.13+
- Tests for thread profile will be **skipped** until env available
- Process profile tests are what we can actually validate

### 3. The Real Integration Points
- Pool → Config (read multi-pool configs)
- Pool → WorkerProfile (start workers via profile)
- Workers → LifecycleManager (registration)
- Pool → LifecycleManager (request counting)

---

## What Tests Can Actually Validate

### With Python 3.12 (current env):
✅ Config parsing and validation
✅ Multi-pool state management
✅ Pool routing logic
✅ Process profile worker startup
✅ TTL recycling (with short TTL)
✅ Request-count recycling
✅ Backward compatibility

### With Python 3.13+ (future env):
✅ Thread profile worker startup
✅ Concurrent request handling
✅ Capacity tracking under load
✅ Thread-safe adapter execution
✅ Performance gains validation

---

## Success Criteria

### For v0.6.0 Release:
1. ✅ All process profile tests pass
2. ✅ Multi-pool config and routing works
3. ✅ Lifecycle recycling works
4. ✅ Backward compatibility verified
5. ⏭️  Thread profile tests skipped (Python 3.13+ required)

### For v0.7.0 (with Python 3.13+):
1. ✅ Thread profile tests pass
2. ✅ Concurrent execution validated
3. ✅ Performance benchmarks confirmed
4. ✅ GIL-free benefits measured

---

## Implementation Estimate

| Step | Complexity | Time | Lines |
|------|-----------|------|-------|
| 1. Config integration | Low | 1 hour | ~50 |
| 2. WorkerProfile integration | Medium | 2 hours | ~100 |
| 3. Multi-pool state | High | 3 hours | ~200 |
| 4. Pool routing | Medium | 2 hours | ~100 |
| 5. Lifecycle wiring | Low | 1 hour | ~20 |
| 6. Verification | - | 1 hour | - |
| **Total** | - | **10 hours** | **~470** |

---

## Next Steps

1. Run baseline tests (watch them fail)
2. Implement Step 1 (Config integration)
3. Run tests, verify 1 passes
4. Implement Step 2 (WorkerProfile)
5. Run tests, verify more pass
6. Continue until all pass

This is **real TDD**: tests first, implementation driven by making tests pass.
