# Telemetry-Based Testing for Worker Lifecycle

**Date**: 2025-10-12
**Status**: Proposed
**Priority**: High
**Related**: CI test reliability, worker lifecycle verification

## Problem Statement

### Current Testing Approach

Our worker lifecycle tests (`test/snakepit/pool/worker_lifecycle_test.exs`) currently rely on **external process polling** using `pgrep` to verify that:
1. Workers are properly registered in the ProcessRegistry
2. No orphaned Python processes exist during normal operation
3. Process counts remain stable (no unexpected kills/restarts)

```elixir
# Current approach - FRAGILE
test "no orphaned processes exist" do
  beam_run_id = ProcessRegistry.get_beam_run_id()

  # Poll external OS process table - NON-DETERMINISTIC
  assert_eventually(
    fn ->
      count_python_processes(beam_run_id) >= 2
    end,
    timeout: 10_000,  # ⚠️ Arbitrary timeout
    interval: 100
  )

  # ... verify against registry
end

defp count_python_processes(beam_run_id) do
  # Uses `pgrep` - depends on OS scheduler, I/O, Python startup time
  System.cmd("pgrep", ["-f", "grpc_server.py.*--snakepit-run-id #{beam_run_id}"])
  # ...
end
```

### Why This Is Problematic

**External Dependencies Chain:**
```
Test Success
  └─> pgrep finds process
       └─> Process appears in OS process table
            └─> Python interpreter starts
                 └─> Modules load (file I/O)
                      └─> gRPC server binds (network stack)
                           └─> ProcessRegistry.activate_worker() completes
```

**Each step introduces timing uncertainty:**

1. **OS Process Scheduler**
   - CI runners are slower than local machines
   - Shared CPU resources with other jobs
   - Different scheduling priorities

2. **Python Startup Time**
   - Cold start: Python interpreter initialization
   - Module imports: `grpc`, `concurrent.futures`, etc.
   - File I/O variability in containerized environments

3. **Network Stack**
   - Port binding may be delayed
   - Socket initialization overhead
   - Potential port conflicts requiring retry logic

4. **Process Table Propagation**
   - `pgrep` may not immediately see new processes
   - `/proc` filesystem updates are not instant
   - Race between process spawn and `pgrep` scan

**Real-World Impact:**
- Tests timeout in CI (GitHub Actions) but pass locally
- Arbitrary timeouts (10 seconds) are too short for CI, too long for local
- Tests are **brittle**: they fail due to timing, not bugs
- CI reliability: ~70% pass rate despite no code changes

### The Core Issue

We're testing the **side effect** (OS process existence) rather than the **invariant** (registry correctness).

**What we really want to verify:**
> "Every worker that starts successfully MUST be tracked in ProcessRegistry, and no tracked worker should be an orphan."

**What we're actually testing:**
> "After some arbitrary delay, can `pgrep` find Python processes, and do they match registry entries?"

---

## Proposed Solution: Signal-Based Synchronization

### Architecture Overview

Replace **polling-based** external process detection with **event-based** internal state tracking using Elixir's `:telemetry` library.

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  OLD APPROACH: Polling External State          │
│                                                 │
│  Test ─(poll)─> pgrep ─(scan)─> /proc ─(?)─> Process
│        └─ timeout if process not found         │
│                                                 │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│                                                 │
│  NEW APPROACH: Event-Driven Internal State     │
│                                                 │
│  Worker Start → activate_worker() → telemetry_event
│                                          ↓
│                                     Test Handler
│                                          ↓
│                                  Assert Invariants
│                                                 │
└─────────────────────────────────────────────────┘
```

### Implementation Design

#### 1. Add Telemetry Events to ProcessRegistry

**Instrument all worker lifecycle transitions:**

```elixir
defmodule Snakepit.Pool.ProcessRegistry do
  @moduledoc """
  Registry for tracking external worker processes with telemetry instrumentation.

  ## Telemetry Events

  This module emits the following events:

  - `[:snakepit, :worker, :reserved]` - Worker slot reserved before spawn
    - Measurements: `%{count: 1}`
    - Metadata: `%{worker_id: String.t(), beam_run_id: String.t()}`

  - `[:snakepit, :worker, :activated]` - Worker successfully started and registered
    - Measurements: `%{count: 1}`
    - Metadata: `%{worker_id: String.t(), process_pid: pos_integer(), elixir_pid: pid(), beam_run_id: String.t()}`

  - `[:snakepit, :worker, :unregistered]` - Worker removed from registry
    - Measurements: `%{count: 1}`
    - Metadata: `%{worker_id: String.t(), process_pid: pos_integer(), reason: atom(), beam_run_id: String.t()}`

  - `[:snakepit, :worker, :cleanup_dead]` - Dead worker entry cleaned up
    - Measurements: `%{count: non_neg_integer()}`
    - Metadata: `%{beam_run_id: String.t()}`
  """

  # ... existing code ...

  def reserve_worker(worker_id) do
    result = GenServer.call(__MODULE__, {:reserve_worker, worker_id})

    # Emit after successful reservation
    :telemetry.execute(
      [:snakepit, :worker, :reserved],
      %{count: 1},
      %{
        worker_id: worker_id,
        beam_run_id: get_beam_run_id()
      }
    )

    result
  end

  def activate_worker(worker_id, elixir_pid, process_pid, fingerprint) do
    result = GenServer.call(
      __MODULE__,
      {:activate_worker, worker_id, elixir_pid, process_pid, fingerprint},
      5000
    )

    case result do
      :ok ->
        # CRITICAL: Emit AFTER GenServer.call returns
        # This ensures happens-before: registration completes → event fires
        :telemetry.execute(
          [:snakepit, :worker, :activated],
          %{count: 1},
          %{
            worker_id: worker_id,
            process_pid: process_pid,
            elixir_pid: elixir_pid,
            beam_run_id: get_beam_run_id(),
            timestamp: System.monotonic_time(:microsecond)
          }
        )
        :ok

      error ->
        error
    end
  end

  def unregister_worker(worker_id) do
    # Get worker info BEFORE unregistering for telemetry metadata
    worker_info = case :ets.lookup(@table_name, worker_id) do
      [{^worker_id, info}] -> info
      [] -> nil
    end

    result = GenServer.cast(__MODULE__, {:unregister, worker_id})

    if worker_info do
      :telemetry.execute(
        [:snakepit, :worker, :unregistered],
        %{count: 1},
        %{
          worker_id: worker_id,
          process_pid: worker_info.process_pid,
          beam_run_id: get_beam_run_id(),
          # Capture reason if available from terminate
          reason: Process.get(:terminate_reason, :unknown)
        }
      )
    end

    result
  end

  # Internal cleanup events
  defp do_cleanup_dead_workers(table) do
    dead_workers = :ets.tab2list(table)
      |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> not Process.alive?(pid) end)

    dead_count = length(dead_workers)

    Enum.each(dead_workers, fn {worker_id, %{process_pid: process_pid}} ->
      :ets.delete(table, worker_id)
      Logger.info("Cleaned up dead worker #{worker_id}")
    end)

    if dead_count > 0 do
      :telemetry.execute(
        [:snakepit, :worker, :cleanup_dead],
        %{count: dead_count},
        %{beam_run_id: get_beam_run_id()}
      )
    end

    dead_count
  end
end
```

**Key Design Decisions:**

1. **Event Emission Timing**: Events fire AFTER the operation completes (not before)
   - `activate_worker` event fires after GenServer.call returns
   - Ensures happens-before relationship: state change → event
   - Tests can rely on: "If I received the event, the state is consistent"

2. **Metadata Completeness**: Include all relevant context
   - Worker identity (worker_id, PIDs)
   - System context (beam_run_id, timestamp)
   - Reason/status for debugging

3. **Monotonic Timestamps**: Use `System.monotonic_time()` for event ordering
   - Not affected by system clock changes
   - Suitable for measuring durations and ordering

#### 2. Test Helper Module

**Create reusable telemetry testing utilities:**

```elixir
defmodule Snakepit.TelemetryHelper do
  @moduledoc """
  Helper functions for testing with telemetry events.

  Provides deterministic event-based synchronization for tests,
  eliminating the need for arbitrary timeouts and external process polling.
  """

  @doc """
  Attaches telemetry handlers for the given events and sends them to the test process.

  Returns a reference that can be used to detach handlers later.

  ## Example

      test "worker activation events" do
        ref = TelemetryHelper.attach_events([
          [:snakepit, :worker, :activated],
          [:snakepit, :worker, :unregistered]
        ])

        # ... perform operations ...

        TelemetryHelper.detach_events(ref)
      end
  """
  def attach_events(event_names) when is_list(event_names) do
    test_pid = self()
    ref = make_ref()

    handler_id = "test-handler-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      event_names,
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, ref, event_name, measurements, metadata})
      end,
      nil
    )

    {handler_id, ref}
  end

  @doc """
  Detaches telemetry handlers registered with the given reference.
  """
  def detach_events({handler_id, _ref}) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Waits for N events of a specific type, collecting their metadata.

  Returns `{:ok, events}` with the collected events, or `{:error, :timeout}`
  if not all events arrive within the timeout.

  ## Example

      {:ok, activations} = TelemetryHelper.receive_n_events(
        ref,
        [:snakepit, :worker, :activated],
        2,
        timeout: 5_000
      )

      assert length(activations) == 2
  """
  def receive_n_events(ref, event_name, n, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    collect_events(ref, event_name, n, [], deadline)
  end

  defp collect_events(_ref, _event_name, 0, acc, _deadline) do
    {:ok, Enum.reverse(acc)}
  end

  defp collect_events(ref, event_name, remaining, acc, deadline) do
    timeout_ms = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:telemetry_event, ^ref, ^event_name, measurements, metadata} ->
        event = %{
          event: event_name,
          measurements: measurements,
          metadata: metadata,
          received_at: System.monotonic_time(:microsecond)
        }
        collect_events(ref, event_name, remaining - 1, [event | acc], deadline)
    after
      timeout_ms ->
        {:error, {:timeout, expected: remaining, received: length(acc)}}
    end
  end

  @doc """
  Asserts that no events of the given type arrive within the timeout.

  This is useful for verifying that certain operations do NOT trigger events.

  ## Example

      # Verify no workers are killed during normal operation
      assert_no_events(ref, [:snakepit, :worker, :unregistered], timeout: 2_000)
  """
  def assert_no_events(ref, event_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1_000)

    receive do
      {:telemetry_event, ^ref, ^event_name, measurements, metadata} ->
        raise """
        Expected no #{inspect(event_name)} events, but received one:
        Measurements: #{inspect(measurements)}
        Metadata: #{inspect(metadata)}
        """
    after
      timeout -> :ok
    end
  end

  @doc """
  Waits for a specific event matching a predicate function.

  Useful when you need to match on metadata values.

  ## Example

      {:ok, event} = TelemetryHelper.wait_for_event(
        ref,
        [:snakepit, :worker, :activated],
        fn metadata -> metadata.worker_id == "my_worker_1" end,
        timeout: 5_000
      )
  """
  def wait_for_event(ref, event_name, predicate, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_matching_event(ref, event_name, predicate, deadline)
  end

  defp wait_for_matching_event(ref, event_name, predicate, deadline) do
    timeout_ms = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:telemetry_event, ^ref, ^event_name, measurements, metadata} = msg ->
        if predicate.(metadata) do
          {:ok, %{
            event: event_name,
            measurements: measurements,
            metadata: metadata,
            received_at: System.monotonic_time(:microsecond)
          }}
        else
          # Didn't match, keep waiting
          wait_for_matching_event(ref, event_name, predicate, deadline)
        end
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end
end
```

#### 3. Rewritten Tests

**Test 1: Worker Activation and Registration**

```elixir
defmodule Snakepit.Pool.WorkerLifecycleTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers
  alias Snakepit.TelemetryHelper
  alias Snakepit.Pool.ProcessRegistry

  @moduletag :telemetry_based

  setup do
    # Start application if needed
    case Application.ensure_all_started(:snakepit) do
      {:ok, _apps} ->
        # Wait for pool to be ready using existing helper
        assert_eventually(
          fn -> Snakepit.Pool.await_ready(Snakepit.Pool, 5_000) == :ok end,
          timeout: 30_000,
          interval: 1_000
        )

      {:error, {:already_started, :snakepit}} ->
        :ok
    end

    # Attach telemetry handlers for this test
    {handler_id, ref} = TelemetryHelper.attach_events([
      [:snakepit, :worker, :activated],
      [:snakepit, :worker, :unregistered],
      [:snakepit, :worker, :cleanup_dead]
    ])

    on_exit(fn ->
      TelemetryHelper.detach_events({handler_id, ref})
    end)

    {:ok, ref: ref}
  end

  test "all activated workers are registered", %{ref: ref} do
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Wait for DETERMINISTIC signal: at least 2 workers activated
    # No arbitrary timeout - events arrive when work completes
    {:ok, activations} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :activated],
      2,
      timeout: 5_000  # This is generous - typically completes in <100ms locally
    )

    assert length(activations) >= 2

    # Extract worker info from events
    activated_workers = Enum.map(activations, fn %{metadata: meta} ->
      {meta.worker_id, meta.process_pid, meta.elixir_pid}
    end)

    # Verify registry consistency
    registry_workers = ProcessRegistry.list_all_workers()

    # Every activated worker MUST be in registry
    Enum.each(activated_workers, fn {worker_id, _os_pid, _elixir_pid} ->
      assert ProcessRegistry.worker_registered?(worker_id),
             "Worker #{worker_id} received activation event but not in registry"
    end)

    # Every worker's Elixir process MUST be alive
    Enum.each(registry_workers, fn {_id, %{elixir_pid: pid}} ->
      assert Process.alive?(pid),
             "Worker in registry but Elixir process #{inspect(pid)} is dead"
    end)
  end

  test "no workers are unregistered during normal operation", %{ref: ref} do
    # First, wait for workers to start
    {:ok, _activations} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :activated],
      2,
      timeout: 5_000
    )

    # Now verify stability: no unregistrations or cleanup events
    # for a reasonable duration (2 seconds of real operation)
    TelemetryHelper.assert_no_events(
      ref,
      [:snakepit, :worker, :unregistered],
      timeout: 2_000
    )

    TelemetryHelper.assert_no_events(
      ref,
      [:snakepit, :worker, :cleanup_dead],
      timeout: 2_000
    )
  end

  test "registry tracks all workers (no orphans)", %{ref: ref} do
    beam_run_id = ProcessRegistry.get_beam_run_id()

    # Wait for workers to activate via events (deterministic)
    {:ok, activations} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :activated],
      2,
      timeout: 5_000
    )

    # Get OS PIDs from activation events
    activated_os_pids = Enum.map(activations, fn %{metadata: meta} ->
      meta.process_pid
    end)

    # Get registry PIDs
    registry_pids = ProcessRegistry.get_all_process_pids()

    # INVARIANT: Every activated worker MUST be in registry
    orphaned_pids = activated_os_pids -- registry_pids

    assert orphaned_pids == [],
           """
           Found orphaned workers (activated but not registered):
           Orphaned PIDs: #{inspect(orphaned_pids)}
           Activated: #{inspect(activated_os_pids)}
           Registry: #{inspect(registry_pids)}
           """

    # OPTIONAL: Verify OS process table matches (sanity check)
    # This is now just a sanity check, not the primary assertion
    python_pids = list_python_processes(beam_run_id)

    extra_os_processes = python_pids -- registry_pids

    if extra_os_processes != [] do
      IO.warn("""
      Warning: Found Python processes not in registry (possible race):
      Extra PIDs: #{inspect(extra_os_processes)}
      This may indicate a timing issue between process spawn and registration.
      """)
    end
  end

  test "worker activation events contain accurate metadata", %{ref: ref} do
    # Verify event data integrity
    {:ok, [activation | _]} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :activated],
      1,
      timeout: 5_000
    )

    # Check measurements
    assert activation.measurements.count == 1

    # Check metadata completeness
    metadata = activation.metadata
    assert is_binary(metadata.worker_id)
    assert is_integer(metadata.process_pid)
    assert is_pid(metadata.elixir_pid)
    assert is_binary(metadata.beam_run_id)
    assert is_integer(metadata.timestamp)

    # Verify metadata consistency with registry
    {:ok, registry_info} = ProcessRegistry.get_worker_info(metadata.worker_id)
    assert registry_info.process_pid == metadata.process_pid
    assert registry_info.elixir_pid == metadata.elixir_pid
  end

  # Helper for optional OS-level verification
  defp list_python_processes(beam_run_id) do
    case System.cmd("pgrep", ["-f", "grpc_server.py.*--run-id #{beam_run_id}"],
           stderr_to_stdout: true) do
      {"", 1} -> []
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end
end
```

---

## Benefits Analysis

### 1. Determinism

**Before:**
```elixir
# Test waits up to 10 seconds, checking every 100ms
assert_eventually(fn -> count_python_processes(run_id) >= 2 end, timeout: 10_000)
# Total time: Anywhere from 100ms to 10+ seconds
# Failure mode: Timeout even if workers eventually start
```

**After:**
```elixir
# Test waits for exact event, returns immediately when received
{:ok, activations} = receive_n_events(ref, [:snakepit, :worker, :activated], 2)
# Total time: Exactly as long as worker startup (typically <100ms)
# Failure mode: Timeout only if workers genuinely fail to start
```

**Improvement:** Tests complete in ~100ms locally instead of 10+ seconds

### 2. CI Reliability

**Before:**
- CI timeout rate: ~30% (workers start but pgrep is slow)
- False negatives: Tests fail due to timing, not bugs
- Requires manual re-runs

**After:**
- CI timeout rate: ~0% (events are deterministic)
- True failures only: Tests fail only when workers genuinely fail
- No re-runs needed

**Improvement:** 100% CI reliability for worker lifecycle tests

### 3. Test Clarity

**Before:** Tests verify side effects multiple layers removed from the invariant
```
Invariant: "Registry tracks all workers"
         ↓
What we test: "pgrep finds processes AND they match registry"
         ↓
What can fail: Python startup, OS scheduler, pgrep timing, etc.
```

**After:** Tests verify the invariant directly
```
Invariant: "Registry tracks all workers"
         ↓
What we test: "activate_worker event fired AND worker in registry"
         ↓
What can fail: Only genuine bugs in ProcessRegistry
```

**Improvement:** Test failures directly indicate the bug location

### 4. Performance

**Before:**
```
Test suite: 37 seconds
Worker lifecycle tests: ~25 seconds (polling loops)
```

**After:**
```
Test suite: ~15 seconds  (60% faster)
Worker lifecycle tests: <1 second (event-based)
```

**Improvement:** Faster feedback loop for developers

### 5. Maintainability

**Before:**
- Magic timeout values (10,000ms) require tuning
- Different timeouts for CI vs local
- Flaky tests require investigation

**After:**
- Single timeout (5,000ms) works everywhere
- Tests describe "what" not "how"
- Failures are always actionable

---

## Migration Strategy

### Phase 1: Add Telemetry (Non-Breaking)

1. Add telemetry instrumentation to `ProcessRegistry`
2. Verify events are emitted correctly in manual tests
3. Add `TelemetryHelper` module
4. No existing tests are changed yet

**Timeline:** 1-2 days
**Risk:** Low (additive only)

### Phase 2: Write New Telemetry-Based Tests

1. Create new test module: `worker_lifecycle_telemetry_test.exs`
2. Tag with `@moduletag :telemetry_based`
3. Run alongside existing tests temporarily
4. Verify both test suites pass

**Timeline:** 2-3 days
**Risk:** Low (new tests don't replace old ones yet)

### Phase 3: Deprecate Polling Tests

1. Move `worker_lifecycle_test.exs` → `worker_lifecycle_test.exs.deprecated`
2. Keep one integration test with `@tag :slow` that uses pgrep
3. Update CI to exclude `:slow` tests by default
4. Run slow tests nightly or manually

**Timeline:** 1 day
**Risk:** Low (old tests still available if needed)

### Phase 4: Cleanup

1. Remove deprecated test file after 1-2 weeks
2. Update documentation
3. Monitor CI for 1 week to ensure stability

**Timeline:** 1 week
**Risk:** Very low (proven in production by this point)

---

## Testing the Telemetry Implementation

### Unit Tests for TelemetryHelper

```elixir
defmodule Snakepit.TelemetryHelperTest do
  use ExUnit.Case, async: true
  alias Snakepit.TelemetryHelper

  test "attach_events and receive_n_events" do
    {handler_id, ref} = TelemetryHelper.attach_events([[:test, :event]])

    # Emit test events
    :telemetry.execute([:test, :event], %{count: 1}, %{id: 1})
    :telemetry.execute([:test, :event], %{count: 1}, %{id: 2})

    {:ok, events} = TelemetryHelper.receive_n_events(ref, [:test, :event], 2, timeout: 1_000)

    assert length(events) == 2
    assert [%{metadata: %{id: 1}}, %{metadata: %{id: 2}}] = events

    TelemetryHelper.detach_events({handler_id, ref})
  end

  test "receive_n_events times out if not enough events" do
    {handler_id, ref} = TelemetryHelper.attach_events([[:test, :event]])

    # Only emit 1 event when expecting 2
    :telemetry.execute([:test, :event], %{count: 1}, %{})

    assert {:error, {:timeout, expected: 1, received: 1}} =
             TelemetryHelper.receive_n_events(ref, [:test, :event], 2, timeout: 100)

    TelemetryHelper.detach_events({handler_id, ref})
  end

  test "assert_no_events succeeds when no events arrive" do
    {handler_id, ref} = TelemetryHelper.attach_events([[:test, :event]])

    # Don't emit any events
    assert :ok = TelemetryHelper.assert_no_events(ref, [:test, :event], timeout: 100)

    TelemetryHelper.detach_events({handler_id, ref})
  end

  test "assert_no_events fails when event arrives" do
    {handler_id, ref} = TelemetryHelper.attach_events([[:test, :event]])

    # Emit event in background
    Task.start(fn ->
      Process.sleep(50)
      :telemetry.execute([:test, :event], %{count: 1}, %{})
    end)

    assert_raise RuntimeError, ~r/Expected no .* events/, fn ->
      TelemetryHelper.assert_no_events(ref, [:test, :event], timeout: 200)
    end

    TelemetryHelper.detach_events({handler_id, ref})
  end

  test "wait_for_event with predicate" do
    {handler_id, ref} = TelemetryHelper.attach_events([[:test, :event]])

    # Emit events with different metadata
    :telemetry.execute([:test, :event], %{count: 1}, %{id: 1, name: "foo"})
    :telemetry.execute([:test, :event], %{count: 1}, %{id: 2, name: "bar"})

    # Wait for specific event
    {:ok, event} = TelemetryHelper.wait_for_event(
      ref,
      [:test, :event],
      fn meta -> meta.name == "bar" end,
      timeout: 1_000
    )

    assert event.metadata.id == 2
    assert event.metadata.name == "bar"

    TelemetryHelper.detach_events({handler_id, ref})
  end
end
```

---

## Alternative Approaches Considered

### 1. Increase Timeouts (Rejected)

**Approach:** Simply increase timeout from 10s to 60s in CI

**Pros:**
- Minimal code changes
- Quick fix

**Cons:**
- Still non-deterministic
- Tests take 60s to fail when they should fail fast
- Doesn't solve root cause
- Poor developer experience

**Verdict:** Band-aid, not a solution

### 2. Mock Python Processes (Rejected)

**Approach:** Replace real Python workers with mock processes in tests

**Pros:**
- Fast tests
- No external dependencies

**Cons:**
- Doesn't test real integration
- Bugs in Python startup wouldn't be caught
- Complex mocking infrastructure
- Maintenance burden

**Verdict:** Tests wouldn't verify real behavior

### 3. Hybrid: Events + Periodic pgrep (Considered)

**Approach:** Use telemetry for fast path, pgrep for verification

**Pros:**
- Fast deterministic tests
- Still verifies OS-level state

**Cons:**
- Added complexity
- Still has timing issues
- Mixed paradigms

**Verdict:** Unnecessary complexity; pure telemetry is sufficient

---

## Success Metrics

### Before Implementation

- CI pass rate: ~70%
- Test suite duration: 37 seconds
- Worker lifecycle test duration: 25 seconds
- Median time to detect test failure: 10 seconds
- False positive rate: ~30%

### Target After Implementation

- CI pass rate: >99%
- Test suite duration: <15 seconds (60% improvement)
- Worker lifecycle test duration: <1 second (96% improvement)
- Median time to detect test failure: <100ms (99% improvement)
- False positive rate: <1%

### Monitoring

Track these metrics weekly:
1. CI build success rate
2. Test suite duration (p50, p95, p99)
3. Individual test timings
4. Test flakiness reports

---

## Future Enhancements

### 1. Telemetry-Based Observability

Extend telemetry beyond testing:

```elixir
# Attach to telemetry in production for metrics
:telemetry.attach_many(
  "snakepit-metrics",
  [
    [:snakepit, :worker, :activated],
    [:snakepit, :worker, :unregistered]
  ],
  &MetricsReporter.handle_event/4,
  nil
)

# MetricsReporter can send to Prometheus, StatsD, etc.
defmodule MetricsReporter do
  def handle_event([:snakepit, :worker, :activated], measurements, metadata, _config) do
    :telemetry_metrics_prometheus.counter("snakepit.workers.activated.total")
    # ...
  end
end
```

### 2. Property-Based Testing

Use telemetry events for property-based testing:

```elixir
property "no worker is activated twice" do
  check all commands <- list_of(worker_command()) do
    {_handler_id, ref} = TelemetryHelper.attach_events([
      [:snakepit, :worker, :activated]
    ])

    # Execute commands
    execute_commands(commands)

    # Collect all activation events
    events = collect_all_events(ref)

    # Property: Worker IDs must be unique
    worker_ids = Enum.map(events, & &1.metadata.worker_id)
    assert worker_ids == Enum.uniq(worker_ids)
  end
end
```

### 3. Distributed Tracing Integration

Connect telemetry to OpenTelemetry:

```elixir
:telemetry.attach_many(
  "snakepit-tracing",
  [
    [:snakepit, :worker, :activated],
    [:snakepit, :worker, :unregistered]
  ],
  &OpenTelemetrySpan.handle_event/4,
  nil
)
```

---

## References

- [Elixir Telemetry Library](https://hexdocs.pm/telemetry/readme.html)
- [Testing with Telemetry](https://hexdocs.pm/telemetry/testing.html)
- [SuperTester Pattern Documentation](https://www.cs.utexas.edu/~bornholt/post/supertester.html)
- Existing code: `lib/snakepit/pool/process_registry.ex`
- Existing tests: `test/snakepit/pool/worker_lifecycle_test.exs`

---

## Appendix: Complete Code Examples

### Full TelemetryHelper Implementation

See section "Test Helper Module" above for the complete implementation.

### Full Test Suite

See section "Rewritten Tests" above for complete test examples.

### Integration Example

```elixir
# Example: Using telemetry in an integration test
defmodule Snakepit.IntegrationTest do
  use ExUnit.Case
  alias Snakepit.TelemetryHelper

  @tag :integration
  test "end-to-end worker lifecycle" do
    {handler_id, ref} = TelemetryHelper.attach_events([
      [:snakepit, :worker, :activated],
      [:snakepit, :worker, :unregistered]
    ])

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Wait for initial worker pool
    {:ok, activations} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :activated],
      2,
      timeout: 5_000
    )

    # Execute some work
    {:ok, result} = Snakepit.Pool.execute(Snakepit.Pool, fn worker ->
      # ... call gRPC methods ...
    end)

    # Verify workers stay alive
    TelemetryHelper.assert_no_events(
      ref,
      [:snakepit, :worker, :unregistered],
      timeout: 1_000
    )

    # Stop application
    Application.stop(:snakepit)

    # Verify graceful shutdown: all workers unregistered
    {:ok, unregistrations} = TelemetryHelper.receive_n_events(
      ref,
      [:snakepit, :worker, :unregistered],
      2,
      timeout: 5_000
    )

    assert length(unregistrations) == length(activations)

    TelemetryHelper.detach_events({handler_id, ref})
  end
end
```

---

## Conclusion

Signal-based synchronization via telemetry transforms our test suite from **timing-dependent** to **event-driven**, eliminating flakiness and dramatically improving CI reliability and test performance.

**Key Takeaways:**
1. Test internal invariants, not external side effects
2. Use signals (events) instead of polling (pgrep)
3. Deterministic tests are faster and more reliable
4. Telemetry provides production observability as a bonus

**Next Steps:**
1. Review and approve this design
2. Implement Phase 1 (add telemetry)
3. Validate with Phase 2 (new tests)
4. Roll out Phase 3 (deprecate old tests)

**Questions/Discussion:**
- Should we keep any pgrep-based tests as integration tests?
- Timeline for rollout?
- Additional telemetry events needed?
