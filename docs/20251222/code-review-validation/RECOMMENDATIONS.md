# Snakepit Code Review - Recommendations

**Date:** 2025-12-22
**Reference:** [FINDINGS.md](./FINDINGS.md)

## Priority Matrix

| Priority | Issue | Impact | Effort |
|----------|-------|--------|--------|
| P1 | Thread profile capacity scheduling | Headline feature broken | Medium |
| P2 | Correlation ID not reaching Python | Observability broken | Low |
| P2 | DETS sync bottleneck | Startup performance | Medium |
| P3 | WorkerProfile.Process adapter_env | Thread safety regression | Trivial |
| P4 | ToolRegistry cleanup_session log | Cosmetic | Trivial |
| P4 | BridgeServer streaming | Feature gap | Medium |

---

## P1: Make Pool Capacity-Aware for Thread Profile

### Problem
Pool uses binary busy/available scheduling. Thread profile's multi-slot capacity is never utilized.

### Solution Approach

**Option A: Unified Load-Based Scheduling (Recommended)**

Transform Pool from binary to load-based scheduling:

```elixir
# lib/snakepit/pool/pool.ex

# Change PoolState struct
defmodule PoolState do
  defstruct [
    ...
    :worker_loads,  # Map: worker_id => current_load
    :worker_capacities,  # Map: worker_id => max_capacity
    ...
  ]
end

# New checkout logic
defp checkout_worker(pool_state, session_id, affinity_cache, profile_module) do
  # Find worker with available capacity
  eligible_worker = find_eligible_worker(pool_state, profile_module)

  case eligible_worker do
    nil -> {:error, :no_workers}
    worker_id ->
      new_loads = Map.update!(pool_state.worker_loads, worker_id, &(&1 + 1))
      {:ok, worker_id, %{pool_state | worker_loads: new_loads}}
  end
end

defp find_eligible_worker(pool_state, profile_module) do
  pool_state.worker_loads
  |> Enum.find(fn {worker_id, load} ->
    capacity = Map.get(pool_state.worker_capacities, worker_id, 1)
    load < capacity
  end)
  |> case do
    {worker_id, _load} -> worker_id
    nil -> nil
  end
end

# On checkin, decrement load instead of moving to available set
defp checkin_worker(pool_state, worker_id) do
  new_loads = Map.update!(pool_state.worker_loads, worker_id, &max(&1 - 1, 0))
  %{pool_state | worker_loads: new_loads}
end
```

**Option B: Profile-Aware Dispatch**

Keep Pool simple, but route through profile module for thread profile:

```elixir
# lib/snakepit/pool/pool.ex

defp execute_on_worker(worker_id, command, args, opts, pool_config) do
  profile_module = Snakepit.Config.get_profile_module(pool_config)

  # Use profile's execute_request which handles capacity
  request = %{command: command, args: args}
  timeout = get_command_timeout(command, args, opts)

  profile_module.execute_request(worker_id, request, timeout)
end
```

This leverages Thread.execute_request's existing `check_and_increment_load/1`.

### Migration Path
1. Add feature flag `:capacity_aware_scheduling` (default: false)
2. Implement Option A or B behind flag
3. Test with thread profile workloads
4. Enable by default in v0.7.0

---

## P2: Fix Correlation ID Propagation

### Problem
`sanitize_parameters/1` strips correlation_id before sending to Python.

### Solution

```elixir
# lib/snakepit/grpc/client_impl.ex

# Change execute_tool to preserve and pass correlation_id
def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  # Extract correlation_id BEFORE sanitization
  correlation_id = extract_correlation_id(parameters)

  parameters = sanitize_parameters(parameters)
  binary_params = Keyword.get(opts, :binary_parameters, %{})

  with {:ok, proto_params} <- encode_parameters(parameters),
       {:ok, encoded_binary} <- encode_binary_parameters(binary_params) do

    # Pass correlation_id to request builder
    request = build_execute_tool_request(
      session_id,
      tool_name,
      proto_params,
      encoded_binary,
      correlation_id
    )
    ...
  end
end

defp extract_correlation_id(parameters) when is_map(parameters) do
  Map.get(parameters, :correlation_id) || Map.get(parameters, "correlation_id")
end

defp build_execute_tool_request(session_id, tool_name, proto_params, binary_params, correlation_id) do
  metadata = if correlation_id do
    %{"correlation_id" => correlation_id}
  else
    %{}
  end

  %Bridge.ExecuteToolRequest{
    session_id: session_id,
    tool_name: tool_name,
    parameters: proto_params,
    binary_parameters: binary_params,
    metadata: metadata
  }
end
```

### Python Side
Ensure Python adapter reads correlation_id from request.metadata:

```python
# priv/python/snakepit_bridge/base_adapter.py

def execute_tool(self, request, context):
    correlation_id = request.metadata.get("correlation_id")
    if correlation_id:
        # Set in thread-local or pass to tool execution
        set_correlation_id(correlation_id)
```

---

## P2: Reduce DETS Sync Frequency

### Problem
`:dets.sync` after every insert creates I/O bottleneck.

### Solution Options

**Option A: Batch Sync (Recommended)**

```elixir
# lib/snakepit/pool/process_registry.ex

# Add batch buffer to state
defstruct [
  ...
  :pending_writes,  # List of pending {worker_id, info} tuples
  :last_sync_time   # Monotonic time of last sync
]

@batch_sync_interval 100  # ms
@max_pending_writes 50

# Queue writes instead of immediate sync
def handle_call({:activate_worker, worker_id, ...}, _from, state) do
  worker_info = build_worker_info(...)

  :ets.insert(state.table, {worker_id, worker_info})
  :dets.insert(state.dets_table, {worker_id, worker_info})

  new_pending = [{worker_id, worker_info} | state.pending_writes]

  state = %{state | pending_writes: new_pending}
  state = maybe_flush_pending(state)

  {:reply, :ok, state}
end

defp maybe_flush_pending(state) do
  now = System.monotonic_time(:millisecond)
  elapsed = now - state.last_sync_time

  if length(state.pending_writes) >= @max_pending_writes or elapsed >= @batch_sync_interval do
    :dets.sync(state.dets_table)
    %{state | pending_writes: [], last_sync_time: now}
  else
    # Schedule async sync if not already scheduled
    unless state.sync_scheduled do
      Process.send_after(self(), :flush_dets, @batch_sync_interval)
    end
    %{state | sync_scheduled: true}
  end
end

def handle_info(:flush_dets, state) do
  :dets.sync(state.dets_table)
  {:noreply, %{state | pending_writes: [], last_sync_time: System.monotonic_time(:millisecond), sync_scheduled: false}}
end
```

**Option B: Accept Small Orphan Window**

Rely on run_id-based cleanup (already implemented) and remove per-operation sync:

```elixir
# Remove :dets.sync calls, rely on auto_save: 1000 configured in init
:dets.open_file(dets_table_name, [
  {:file, to_charlist(dets_file)},
  {:type, :set},
  {:auto_save, 1000},  # Already configured
  {:repair, true}
])
```

Risk: Up to 1 second of writes could be lost on crash. Run-id cleanup handles orphans on next startup.

### Recommendation
Option B is simpler and the run_id cleanup mechanism is robust. The 1-second window is acceptable given the existing cleanup strategy.

---

## P3: Fix WorkerProfile.Process adapter_env

### Problem
`build_process_env/1` result is discarded.

### Solution

```elixir
# lib/snakepit/worker_profile/process.ex:44-67

def start_worker(config) do
  worker_id = Map.fetch!(config, :worker_id)
  worker_module = Map.get(config, :worker_module, Snakepit.GRPCWorker)
  adapter_module = Map.fetch!(config, :adapter_module)
  pool_name = Map.get(config, :pool_name, Snakepit.Pool)

  # Build and APPLY adapter environment
  adapter_env = build_process_env(config)
  config_with_env = Map.update(config, :adapter_env, adapter_env, fn existing ->
    # Merge: user-specified env takes precedence
    Keyword.merge(adapter_env, existing || [])
  end)

  case Snakepit.Pool.WorkerSupervisor.start_worker(
         worker_id,
         worker_module,
         adapter_module,
         pool_name,
         config_with_env  # <-- Use config with env applied
       ) do
    {:ok, pid} ->
      SLog.debug("Process profile started worker #{worker_id}: #{inspect(pid)}")
      {:ok, pid}

    error ->
      error
  end
end
```

---

## P4: Fix ToolRegistry cleanup_session Log

### Problem
`:ets.match_delete/2` returns `true`, not count.

### Solution

```elixir
# lib/snakepit/bridge/tool_registry.ex:224-230

def handle_call({:cleanup_session, session_id}, _from, state) do
  pattern = {{session_id, :_}, :_}

  # Count before delete
  tools = :ets.match_object(@table_name, pattern)
  num_tools = length(tools)

  :ets.match_delete(@table_name, pattern)

  SLog.debug("Cleaned up #{num_tools} tools for session: #{session_id}")

  {:reply, :ok, state}
end
```

---

## P4: BridgeServer Streaming

### Problem
Server-side streaming returns UNIMPLEMENTED.

### Recommendation
This is a feature gap, not a bug. Options:
1. **Document limitation** - Streaming only available via direct worker connection
2. **Implement server streaming** - Forward streaming to workers similar to execute_tool
3. **Remove client API** - If server streaming won't be supported

Given the complexity, documenting the limitation is recommended for now.

---

## Implementation Order

1. **Week 1**: P3 (adapter_env) + P4 (cleanup log) - trivial fixes
2. **Week 2**: P2 (correlation ID) - improves debugging immediately
3. **Week 3-4**: P2 (DETS batch sync) - measure startup time before/after
4. **v0.7.0**: P1 (capacity-aware scheduling) - requires thorough testing

---

## Testing Checklist

### Thread Profile Capacity
- [ ] Start pool with `worker_profile: :thread, threads_per_worker: 4, pool_size: 2`
- [ ] Fire 8 concurrent requests
- [ ] Verify all 8 execute in parallel (not serialized to 2)
- [ ] Verify CapacityStore load tracking matches actual in-flight requests

### Correlation ID
- [ ] Send request with explicit correlation_id
- [ ] Verify Python logs contain same correlation_id
- [ ] Verify Elixir logs contain same correlation_id
- [ ] Test auto-generated correlation_id propagates

### DETS Performance
- [ ] Benchmark pool startup time with 100 workers (before)
- [ ] Apply batch sync or remove sync
- [ ] Benchmark pool startup time (after)
- [ ] Verify orphan cleanup still works after simulated crash

### adapter_env
- [ ] Configure process profile pool
- [ ] Verify Python worker has `OPENBLAS_NUM_THREADS=1` in environment
- [ ] Run NumPy workload, verify single-threaded execution
