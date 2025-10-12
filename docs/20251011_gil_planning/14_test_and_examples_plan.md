# Snakepit v0.6.0 Test & Examples Implementation Plan

**Date**: 2025-10-11
**Status**: Implementation Plan
**Purpose**: Validate v0.6.0 dual-mode architecture through comprehensive tests and examples

---

## Overview

This document outlines the test suite and example scripts needed to validate Snakepit v0.6.0's dual-mode parallelism architecture. The tests ensure all components work correctly, while examples demonstrate real-world usage patterns.

---

## Test Suite Structure

### Test Organization

```
test/
├── snakepit/
│   ├── worker_profile_test.exs           # WorkerProfile behaviour tests
│   ├── python_version_test.exs           # Python detection tests
│   ├── compatibility_test.exs            # Library compatibility tests
│   ├── config_test.exs                   # Configuration validation tests
│   ├── worker_profile/
│   │   ├── process_test.exs              # Process profile tests
│   │   └── thread_test.exs               # Thread profile tests
│   ├── worker/
│   │   └── lifecycle_manager_test.exs    # Lifecycle management tests
│   └── diagnostics/
│       └── profile_inspector_test.exs    # Diagnostic tests
```

---

## Test Requirements

### 1. Unit Tests (Fast, No External Dependencies)

#### Test: `test/snakepit/python_version_test.exs`
**Purpose**: Validate Python version detection

**Test Cases:**
1. Parse version strings correctly
2. Detect free-threading support (3.13+)
3. Recommend appropriate profile
4. Handle missing Python gracefully
5. Validate minimum requirements

**Lines**: ~150

#### Test: `test/snakepit/compatibility_test.exs`
**Purpose**: Validate library compatibility checking

**Test Cases:**
1. Check thread-safe libraries (NumPy, PyTorch)
2. Check thread-unsafe libraries (Pandas, Matplotlib)
3. Generate compatibility reports
4. Handle unknown libraries
5. Python version compatibility checking

**Lines**: ~200

#### Test: `test/snakepit/config_test.exs`
**Purpose**: Validate configuration system

**Test Cases:**
1. Legacy config conversion
2. Multi-pool validation
3. Profile-specific defaults
4. Error handling (missing fields, invalid values)
5. Normalization logic
6. Duplicate pool name detection

**Lines**: ~250

### 2. Integration Tests (Require Worker Processes)

#### Test: `test/snakepit/worker_profile/process_test.exs`
**Purpose**: Validate process profile implementation

**Test Cases:**
1. Start single-threaded worker
2. Verify environment variables set correctly
3. Execute requests successfully
4. Capacity always returns 1
5. Health checks work
6. Metadata correct

**Lines**: ~200

#### Test: `test/snakepit/worker_profile/thread_test.exs`
**Purpose**: Validate thread profile implementation

**Test Cases:**
1. Start multi-threaded worker
2. Verify threaded script selected
3. Capacity tracking via ETS
4. Concurrent request handling
5. Load increment/decrement
6. At-capacity error handling
7. Metadata with capacity info

**Lines**: ~300

#### Test: `test/snakepit/worker/lifecycle_manager_test.exs`
**Purpose**: Validate lifecycle management

**Test Cases:**
1. TTL-based recycling
2. Request-count recycling
3. Worker tracking registration
4. Graceful worker replacement
5. Telemetry event emission
6. Health check monitoring
7. Statistics reporting

**Lines**: ~350

#### Test: `test/snakepit/diagnostics/profile_inspector_test.exs`
**Purpose**: Validate diagnostic tools

**Test Cases:**
1. Get pool stats (both profiles)
2. Capacity analysis
3. Memory stats
4. Recommendations generation
5. Saturation checking
6. Multi-pool reports

**Lines**: ~200

### 3. End-to-End Tests

#### Test: `test/snakepit/dual_mode_integration_test.exs`
**Purpose**: Validate complete dual-mode system

**Test Cases:**
1. Start pools with both profiles simultaneously
2. Execute on process profile
3. Execute on thread profile
4. Verify capacity tracking
5. Lifecycle management working
6. Telemetry events emitted
7. Diagnostics report both pools

**Lines**: ~300

**Total Test Lines**: ~1,950

---

## Example Scripts

### Example Organization

```
examples/
├── dual_mode/
│   ├── process_vs_thread_comparison.exs    # Side-by-side comparison
│   ├── hybrid_pools.exs                    # Multiple pools, different profiles
│   └── performance_benchmark.exs           # Real performance testing
├── lifecycle/
│   ├── ttl_recycling_demo.exs              # TTL-based recycling
│   ├── request_count_recycling_demo.exs    # Request-based recycling
│   └── manual_recycling_demo.exs           # Manual worker management
├── monitoring/
│   ├── telemetry_basic.exs                 # Basic telemetry setup
│   ├── prometheus_integration.exs          # Prometheus metrics
│   └── diagnostics_demo.exs                # Using diagnostic tools
└── migration/
    ├── v0.5_legacy_config.exs              # Old config still works
    └── v0.6_new_config.exs                 # New multi-pool config
```

---

## Example Scripts Details

### 1. Process vs Thread Comparison (`dual_mode/process_vs_thread_comparison.exs`)
**Purpose**: Side-by-side comparison of both profiles

**Demonstrates:**
- Configuring both profiles
- Executing same workload on both
- Comparing execution time
- Comparing memory usage
- Showing capacity differences

**Lines**: ~250

**Output:**
```
Process Profile (100 workers):
  Execution Time: 10.5s
  Memory Usage: 15 GB
  Capacity: 100

Thread Profile (4×16 workers):
  Execution Time: 2.8s (3.75× faster!)
  Memory Usage: 1.6 GB (9.4× less!)
  Capacity: 64

Recommendation: Thread profile optimal for CPU-bound workloads
```

### 2. Hybrid Pools (`dual_mode/hybrid_pools.exs`)
**Purpose**: Show multiple pools with different profiles

**Demonstrates:**
- Configuring multiple named pools
- Process profile for API workload
- Thread profile for CPU workload
- Routing requests to appropriate pool
- Pool-specific statistics

**Lines**: ~200

### 3. TTL Recycling Demo (`lifecycle/ttl_recycling_demo.exs`)
**Purpose**: Show TTL-based worker recycling

**Demonstrates:**
- Configure short TTL (30 seconds for demo)
- Monitor worker startup
- Wait for TTL expiration
- Observe automatic recycling
- Verify new worker started
- Check telemetry events

**Lines**: ~180

### 4. Request Count Recycling (`lifecycle/request_count_recycling_demo.exs`)
**Purpose**: Show request-count based recycling

**Demonstrates:**
- Configure max_requests (e.g., 10 for demo)
- Execute multiple requests
- Monitor request count
- Observe recycling after threshold
- Verify zero downtime

**Lines**: ~150

### 5. Telemetry Basic (`monitoring/telemetry_basic.exs`)
**Purpose**: Basic telemetry integration

**Demonstrates:**
- Attaching telemetry handlers
- Listening for worker recycling
- Listening for pool saturation
- Listening for request execution
- Printing telemetry data

**Lines**: ~200

### 6. Diagnostics Demo (`monitoring/diagnostics_demo.exs`)
**Purpose**: Using diagnostic tools

**Demonstrates:**
- ProfileInspector API usage
- Getting pool statistics
- Capacity analysis
- Memory tracking
- Recommendations
- Mix task integration

**Lines**: ~180

### 7. Performance Benchmark (`dual_mode/performance_benchmark.exs`)
**Purpose**: Real performance measurement

**Demonstrates:**
- CPU-intensive workload
- Both profiles tested
- Time measurement
- Memory measurement
- Throughput calculation
- Results comparison

**Lines**: ~300

**Total Example Lines**: ~1,460

---

## Implementation Strategy

### Phase 1: Unit Tests (No External Dependencies)
1. python_version_test.exs
2. compatibility_test.exs
3. config_test.exs

**Estimated Time**: 2 hours
**Lines**: ~600

### Phase 2: Profile Tests (Basic Integration)
1. process_test.exs
2. thread_test.exs

**Estimated Time**: 3 hours
**Lines**: ~500

### Phase 3: Lifecycle & Diagnostics Tests
1. lifecycle_manager_test.exs
2. profile_inspector_test.exs

**Estimated Time**: 3 hours
**Lines**: ~550

### Phase 4: End-to-End Test
1. dual_mode_integration_test.exs

**Estimated Time**: 2 hours
**Lines**: ~300

### Phase 5: Example Scripts
1. All 7 example scripts

**Estimated Time**: 4 hours
**Lines**: ~1,460

**Total Estimated Time**: 14 hours
**Total Lines**: ~3,410

---

## Test Patterns

### Pattern 1: Unit Test (No Process Startup)

```elixir
defmodule Snakepit.PythonVersionTest do
  use ExUnit.Case, async: true

  describe "detect/1" do
    test "parses Python version correctly" do
      # Mock System.cmd to avoid actual Python call
      # Test parsing logic
      assert {:ok, {3, 13, 0}} = parse_version("Python 3.13.0")
    end
  end
end
```

### Pattern 2: Integration Test (With Workers)

```elixir
defmodule Snakepit.WorkerProfile.ThreadTest do
  use ExUnit.Case, async: false

  setup do
    # Start minimal pool for testing
    config = %{
      worker_id: "test_worker_#{:rand.uniform(10000)}",
      worker_profile: :thread,
      threads_per_worker: 4,
      adapter_module: Snakepit.Adapters.GRPCPython,
      pool_name: self()
    }

    on_exit(fn ->
      # Cleanup
    end)

    {:ok, config: config}
  end

  test "starts multi-threaded worker", %{config: config} do
    assert {:ok, pid} = Snakepit.WorkerProfile.Thread.start_worker(config)
    assert Process.alive?(pid)
    assert Snakepit.WorkerProfile.Thread.get_capacity(pid) == 4
  end
end
```

### Pattern 3: Example Script

```elixir
#!/usr/bin/env elixir

Mix.install([{:snakepit, path: ".."}])

# Configure pools
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pools, [
  %{name: :demo, worker_profile: :process, pool_size: 4}
])

# Run demo
Snakepit.run_as_script(fn ->
  IO.puts("Executing on process profile...")
  {:ok, result} = Snakepit.execute(:demo, "ping", %{})
  IO.inspect(result, label: "Result")
end)
```

---

## Testing Checklist

### Unit Tests
- [ ] Python version detection
- [ ] Compatibility matrix
- [ ] Configuration validation
- [ ] Config normalization
- [ ] Profile module selection

### Integration Tests
- [ ] Process profile worker startup
- [ ] Thread profile worker startup
- [ ] Capacity tracking (ETS)
- [ ] Load balancing
- [ ] Concurrent requests (thread profile)
- [ ] Worker recycling (TTL)
- [ ] Worker recycling (request count)
- [ ] Health checks
- [ ] Telemetry events

### End-to-End Tests
- [ ] Dual-mode pools running simultaneously
- [ ] Request routing to correct profile
- [ ] Lifecycle management operational
- [ ] Diagnostics report accurate data

### Example Scripts
- [ ] All examples run without errors
- [ ] Output is clear and educational
- [ ] Configuration examples valid
- [ ] Demonstrates key features

---

## Success Criteria

### Tests Pass
- ✅ All unit tests pass
- ✅ All integration tests pass
- ✅ All E2E tests pass
- ✅ No warnings or deprecations
- ✅ Clean test output

### Examples Work
- ✅ All examples executable
- ✅ Clear, educational output
- ✅ No errors or crashes
- ✅ Demonstrates v0.6.0 features

### Coverage
- ✅ Core modules tested
- ✅ Both profiles tested
- ✅ Lifecycle management tested
- ✅ Diagnostics tested
- ✅ Configuration tested

---

## Implementation Order

1. **Unit Tests First** (fastest, no dependencies)
   - PythonVersion
   - Compatibility
   - Config

2. **Profile Tests** (basic integration)
   - ProcessProfile
   - ThreadProfile

3. **Advanced Tests** (full integration)
   - LifecycleManager
   - ProfileInspector

4. **Examples** (demonstrate features)
   - Dual-mode comparison
   - Lifecycle demos
   - Monitoring demos

5. **Documentation** (final polish)
   - Update test documentation
   - Add test running instructions
   - Document example usage

---

## Expected Test Output

```bash
$ mix test

Compiling 15 files (.ex)
Generated snakepit app

...............................................................

Finished in 12.5 seconds (8.0s async, 4.5s sync)
65 tests, 0 failures

Randomized with seed 123456

Test Coverage:
  lib/snakepit/worker_profile.ex: 100%
  lib/snakepit/python_version.ex: 95%
  lib/snakepit/compatibility.ex: 92%
  lib/snakepit/config.ex: 94%
  lib/snakepit/worker_profile/process.ex: 88%
  lib/snakepit/worker_profile/thread.ex: 85%
  lib/snakepit/worker/lifecycle_manager.ex: 82%
  lib/snakepit/diagnostics/profile_inspector.ex: 90%

Overall: 91% coverage
```

---

## Example Script Output Previews

### Process vs Thread Comparison

```
$ mix run examples/dual_mode/process_vs_thread_comparison.exs

======================================================================
Snakepit v0.6.0 - Process vs Thread Profile Comparison
======================================================================

Starting Process Profile Pool (100 workers)...
  ✓ 100 workers started in 3.2s
  Memory: 15 GB

Starting Thread Profile Pool (4 workers × 16 threads)...
  ✓ 4 workers started in 0.9s
  Memory: 1.6 GB

Running CPU-Intensive Workload (1000 requests)...

Process Profile Results:
  Duration: 45.2s
  Throughput: 22.1 req/s
  Memory: 15.2 GB (stable)

Thread Profile Results:
  Duration: 12.8s (3.5× faster!)
  Throughput: 78.1 req/s (3.5× higher!)
  Memory: 1.8 GB (9.4× less!)

Recommendation: Thread profile optimal for this workload
======================================================================
```

### Lifecycle Recycling Demo

```
$ mix run examples/lifecycle/ttl_recycling_demo.exs

======================================================================
Worker Lifecycle Management - TTL Recycling Demo
======================================================================

Configuration:
  TTL: 30 seconds
  Pool: :demo_pool
  Workers: 2

Starting workers...
  ✓ Worker pool_worker_1 started at T=0s
  ✓ Worker pool_worker_2 started at T=0s

Monitoring worker lifecycle...
  T=10s  - Both workers healthy, 0 requests
  T=20s  - Both workers healthy, 0 requests
  T=30s  - Both workers healthy, 0 requests
  T=40s  - pool_worker_1 TTL expired, recycling...
  T=41s  - pool_worker_1 recycled → pool_worker_3 started
  T=50s  - pool_worker_2 TTL expired, recycling...
  T=51s  - pool_worker_2 recycled → pool_worker_4 started

Telemetry Events Received:
  [:snakepit, :worker, :recycled] - pool_worker_1 (reason: ttl_expired)
  [:snakepit, :worker, :recycled] - pool_worker_2 (reason: ttl_expired)

✓ Lifecycle management working correctly!
======================================================================
```

---

## Testing Infrastructure Needs

### 1. Test Helpers

```elixir
# test/support/test_helpers.ex
defmodule Snakepit.TestHelpers do
  def start_test_pool(opts) do
    # Start minimal pool for testing
  end

  def wait_for_worker_ready(worker_id, timeout \\ 5000) do
    # Poll until worker reports ready
  end

  def cleanup_test_workers do
    # Ensure all test workers stopped
  end

  def assert_telemetry_emitted(event, timeout \\ 1000) do
    # Wait for telemetry event
  end
end
```

### 2. Mock Adapters

```elixir
# test/support/mock_adapter.ex
defmodule Snakepit.Test.MockAdapter do
  @behaviour Snakepit.Adapter

  def executable_path, do: System.find_executable("python3")
  def script_path, do: "test/support/mock_server.py"
  def script_args, do: ["--test-mode"]
  # ...
end
```

### 3. Test Configuration

```elixir
# test/test_helper.exs
ExUnit.start(capture_log: true)

# Ensure clean state
Application.stop(:snakepit)
Application.load(:snakepit)

# Test-specific configuration
Application.put_env(:snakepit, :pooling_enabled, false)
```

---

## Implementation Plan

### Step 1: Unit Tests (Day 1, AM)
- [x] Create test_helper.exs
- [ ] python_version_test.exs
- [ ] compatibility_test.exs
- [ ] config_test.exs
- [ ] Run: `mix test test/snakepit/*_test.exs`

### Step 2: Profile Tests (Day 1, PM)
- [ ] Create test helpers
- [ ] process_test.exs
- [ ] thread_test.exs
- [ ] Run: `mix test test/snakepit/worker_profile/`

### Step 3: Advanced Tests (Day 2, AM)
- [ ] lifecycle_manager_test.exs
- [ ] profile_inspector_test.exs
- [ ] Run: `mix test test/snakepit/worker/`

### Step 4: E2E Tests (Day 2, PM)
- [ ] dual_mode_integration_test.exs
- [ ] Run: `mix test test/snakepit/dual_mode_integration_test.exs`

### Step 5: Examples (Day 3)
- [ ] process_vs_thread_comparison.exs
- [ ] hybrid_pools.exs
- [ ] ttl_recycling_demo.exs
- [ ] request_count_recycling_demo.exs
- [ ] telemetry_basic.exs
- [ ] diagnostics_demo.exs
- [ ] performance_benchmark.exs

### Step 6: Validation (Day 3, PM)
- [ ] Run all tests: `mix test`
- [ ] Run all examples
- [ ] Verify output quality
- [ ] Update documentation

---

## Acceptance Criteria

### For Tests
1. ✅ All tests pass
2. ✅ No flaky tests
3. ✅ Clean output (no warnings)
4. ✅ Coverage ≥85%
5. ✅ Fast execution (<30s total)

### For Examples
1. ✅ All examples run successfully
2. ✅ Clear, educational output
3. ✅ Demonstrate key features
4. ✅ No errors or crashes
5. ✅ Copy-paste ready configurations

---

## Conclusion

This test and example plan provides comprehensive validation of Snakepit v0.6.0:

- **~1,950 lines** of tests covering all components
- **~1,460 lines** of examples demonstrating features
- **Total: ~3,410 lines** of validation code

Once implemented, this will ensure v0.6.0 is production-ready and well-demonstrated.

**Next Steps**: Implement tests and examples per this plan.
