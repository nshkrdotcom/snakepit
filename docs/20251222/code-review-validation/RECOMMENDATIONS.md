# Snakepit Code Review - Recommendations

**Date:** 2025-12-22
**Reference:** [FINDINGS.md](./FINDINGS.md)

## Start Here (Implementation Orientation)

This doc assumes `FINDINGS.md` is correct and focuses on what to change. If you need evidence, jump back to the findings.

Non-goals for this pass:
- DETS sync/performance changes (leave as-is for crash safety).
- Server-side streaming implementation (document the limitation unless you explicitly commit to build it).

Quick change map (files you will almost certainly touch):
- Elixir: `lib/snakepit/pool/pool.ex`, `lib/snakepit/grpc/client_impl.ex`, `lib/snakepit/grpc_worker.ex`, `lib/snakepit/worker_profile/process.ex`, `lib/snakepit/bridge/tool_registry.ex`, `lib/snakepit/config.ex`
- Python: `priv/python/grpc_server.py`, `priv/python/grpc_server_threaded.py`, `priv/python/snakepit_bridge/otel_tracing.py`
- Tests: `test/` (pool scheduling + session affinity + correlation + env merge), `priv/python/tests/` (telemetry + request metadata)

Definition of done (for this pass):
- Correlation ID is present in gRPC metadata header and `ExecuteToolRequest.metadata` for both execute and streaming paths.
- Pool scheduling honors per-worker capacity and preserves session affinity when capacity remains.
- `:capacity_strategy` config is documented, default is `:pool`.
- Process profile env merge preserves system-level thread limits and allows user overrides.
- ToolRegistry cleanup log reports a count (not `true`).

## Priority Matrix

| Priority | Issue | Impact | Effort |
|----------|-------|--------|--------|
| P1 | Thread profile capacity scheduling | Headline feature broken | Medium |
| P1 | Correlation ID propagation (header + metadata) | Observability correctness | Low |
| P2 | WorkerProfile.Process adapter_env | Thread safety regression | Trivial |
| P3 | ToolRegistry cleanup_session log | Cosmetic | Trivial |
| P4 | BridgeServer streaming | Feature gap | Medium |
| P4 | DETS sync bottleneck (defer; keep current behavior) | Startup performance | Medium |

---

## P1: Make Pool Capacity-Aware for Thread Profile

### Problem
Pool uses binary busy/available scheduling. Thread profile's multi-slot capacity is never utilized.

### Solution Approach

**Option A: Capacity-Aware Pool State (Recommended)**

Convert Pool from binary busy/available to per-worker load tracking, while preserving session affinity:

- Replace `busy` with `worker_loads` (worker_id => in-flight count)
- Keep `available` as "workers with remaining capacity"
- On checkout: prefer the affinity worker if `load < capacity`, else pick any available worker
- On checkin: decrement load and re-add to available when `load < capacity`
- If you still want CapacityStore/telemetry from the thread profile, update it from Pool or route through the profile module without double-counting
- Populate `worker_capacities` from pool config (`threads_per_worker`) or `profile_module.get_capacity/1` at worker registration
- Preserve thread-limit behavior (system env + per-worker adapter_env) so `threads_per_worker` does not regress the existing Python safety constraints

```elixir
# lib/snakepit/pool/pool.ex (illustrative)

defmodule PoolState do
  defstruct [
    ...
    :worker_loads,       # worker_id => in-flight count
    :worker_capacities,  # worker_id => max capacity
    :available,          # MapSet of workers with load < capacity
    ...
  ]
end

defp checkout_worker(pool_state, session_id, affinity_cache) do
  case try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
    {:ok, worker_id, new_state} ->
      {:ok, worker_id, new_state}

    :no_preferred_worker ->
      case Enum.take(pool_state.available, 1) do
        [worker_id] -> increment_load(pool_state, worker_id, session_id)
        [] -> {:error, :no_workers}
      end
  end
end

defp increment_load(pool_state, worker_id, session_id) do
  new_loads = Map.update(pool_state.worker_loads, worker_id, 1, &(&1 + 1))
  capacity = Map.get(pool_state.worker_capacities, worker_id, 1)

  new_available =
    if new_loads[worker_id] < capacity do
      pool_state.available
    else
      MapSet.delete(pool_state.available, worker_id)
    end

  if session_id, do: store_session_affinity(session_id, worker_id)
  {:ok, worker_id, %{pool_state | worker_loads: new_loads, available: new_available}}
end

defp checkin_worker(pool_state, worker_id) do
  new_loads = Map.update(pool_state.worker_loads, worker_id, 0, &max(&1 - 1, 0))
  capacity = Map.get(pool_state.worker_capacities, worker_id, 1)

  new_available =
    if new_loads[worker_id] < capacity do
      MapSet.put(pool_state.available, worker_id)
    else
      pool_state.available
    end

  %{pool_state | worker_loads: new_loads, available: new_available}
end
```

**Configuration (recommended)**

Expose a capacity strategy that can be set globally and overridden per pool:

- `:capacity_strategy` = `:pool` (default) - Pool tracks load/capacity and schedules accordingly
- `:capacity_strategy` = `:profile` - advanced use only; only valid if callers invoke profile module directly
- `:capacity_strategy` = `:hybrid` - Pool schedules; profile tracks load for telemetry/CapacityStore

For the 80% case, `:pool` is sufficient and the least surprising. `:hybrid` is architecturally cleaner if you want profile-level telemetry without coupling scheduling to the profile implementation.

**Option B: Profile-Aware Checkout (Smaller Change, Still Requires Pool Changes)**

Routing only `execute_on_worker` through `profile_module.execute_request/3` is **not sufficient** because the Pool still checks out a worker as a single-capacity slot. To make this viable:

- Allow multiple concurrent checkouts for the same worker when `profile_module.get_load/1 < get_capacity/1`
- If `profile_module.execute_request/3` returns `{:error, :worker_at_capacity}`, retry with another worker or enqueue
- Ensure streaming paths either participate in capacity accounting or are explicitly documented as single-slot

### Migration Path
1. Add feature flag `:capacity_aware_scheduling` (default: false)
2. Implement Option A or B behind flag
3. Test with thread profile workloads
4. Enable by default in v0.7.0

---

## P1: Fix Correlation ID Propagation

### Problem
`sanitize_parameters/1` strips correlation_id before sending to Python, and the gRPC client never sets the `x-snakepit-correlation-id` header that Python's telemetry expects. We want correlation_id in **both** the gRPC metadata header and the request metadata map.

### Solution

```elixir
# lib/snakepit/grpc/client_impl.ex

# Change execute_tool to preserve and pass correlation_id
def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  correlation_id = extract_correlation_id(parameters)

  parameters = sanitize_parameters(parameters)
  binary_params = Keyword.get(opts, :binary_parameters, %{})

  with {:ok, proto_params} <- encode_parameters(parameters),
       {:ok, encoded_binary} <- encode_binary_parameters(binary_params) do

    metadata = build_request_metadata(correlation_id)
    request =
      build_execute_tool_request(
        session_id,
        tool_name,
        proto_params,
        encoded_binary,
        metadata
      )
    timeout = opts[:timeout] || @default_timeout
    call_opts = [timeout: timeout] |> maybe_put_correlation_metadata(correlation_id)
    ...
  end
end

defp extract_correlation_id(parameters) when is_map(parameters) do
  Map.get(parameters, :correlation_id) || Map.get(parameters, "correlation_id")
end
defp extract_correlation_id(parameters) when is_list(parameters) do
  Enum.find_value(parameters, fn
    {:correlation_id, value} -> value
    {"correlation_id", value} -> value
    _ -> nil
  end)
end
defp extract_correlation_id(_), do: nil

defp build_execute_tool_request(session_id, tool_name, proto_params, binary_params, metadata) do
  %Bridge.ExecuteToolRequest{
    session_id: session_id,
    tool_name: tool_name,
    parameters: proto_params,
    binary_parameters: binary_params,
    metadata: metadata
  }
end

defp build_request_metadata(nil), do: %{}
defp build_request_metadata(correlation_id), do: %{"correlation_id" => correlation_id}

defp maybe_put_correlation_metadata(call_opts, nil), do: call_opts
defp maybe_put_correlation_metadata(call_opts, correlation_id) do
  Keyword.put(call_opts, :metadata, [{"x-snakepit-correlation-id", correlation_id}])
end
```

Apply the same `maybe_put_correlation_metadata/2` logic in `execute_streaming_tool/5` so streaming requests carry the header as well.
Also ensure streaming requests have a correlation_id (e.g., call `ensure_correlation/1` in `GRPCWorker.handle_call({:execute_stream, ...})` or generate one in the gRPC client when missing).

### Python Side
Ensure Python servers apply the gRPC metadata header to the telemetry context (threaded server already does), and pass the request metadata into adapter context for tool code that expects it:

```python
# priv/python/grpc_server.py

async def ExecuteTool(self, request, context):
    metadata = context.invocation_metadata()
    correlation_id = request.metadata.get("correlation_id")
    if correlation_id:
        telemetry.set_correlation_id(correlation_id)
    with telemetry.otel_span(
        "BridgeService/ExecuteTool",
        context_metadata=metadata,
        attributes={"snakepit.session_id": request.session_id, "snakepit.tool": request.tool_name},
    ):
        ...
```

Treat the gRPC header as the source of truth for tracing; use `request.metadata` as a mirror for adapters and debugging.

---

## P2: Fix WorkerProfile.Process adapter_env

### Problem
`build_process_env/1` result is discarded.

Note: `GRPCWorker` sets `{:env, ...}` when `adapter_env` is non-empty; if that replaces inherited env, dropping thread-limit variables becomes more likely unless they are explicitly merged.

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

## P3: Fix ToolRegistry cleanup_session Log

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

## P4: DETS Sync Bottleneck (Defer; Correctness First)

### Problem
Immediate `:dets.sync` calls can be a startup bottleneck, but they are intentionally used to guarantee crash persistence and robust orphan cleanup.

### Decision (Current)
- Keep immediate sync on reserve/register/activate.
- Do not batch or remove sync in this phase.
- If this is revisited later, re-validate orphan cleanup guarantees and update `README_PROCESS_MANAGEMENT.md` and related tests.

### Recommendation
No change while correctness is the priority.

---

## Implementation Order

1. **Phase 1 (low effort, correctness)**: P1 (correlation header + metadata) + P2 (adapter_env) + P3 (cleanup log)
2. **Phase 2 (core behavior)**: P1 (capacity-aware scheduling) with full concurrency and affinity tests
3. **Deferred**: P4 (BridgeServer streaming) and P4 (DETS sync optimization) until correctness work is complete

---

## Testing Checklist

### Thread Profile Capacity
- [ ] Start pool with `worker_profile: :thread, threads_per_worker: 4, pool_size: 2`
- [ ] Fire 8 concurrent requests
- [ ] Verify all 8 execute in parallel (not serialized to 2)
- [ ] Verify CapacityStore load tracking matches actual in-flight requests
- [ ] Verify session affinity prefers the same worker when capacity is available
- [ ] Verify `:capacity_strategy` default is documented and behaves as expected (`:pool` or `:hybrid`)
- [ ] Confirm Python thread-limit env remains correct when `threads_per_worker` is used

### Correlation ID
- [ ] Send request with explicit correlation_id
- [ ] Verify `ExecuteToolRequest.metadata["correlation_id"]` is set
- [ ] Verify gRPC metadata header `x-snakepit-correlation-id` is set on ExecuteTool/ExecuteStreamingTool
- [ ] Verify Python logs contain same correlation_id (from header)
- [ ] Verify Elixir logs contain same correlation_id
- [ ] Test auto-generated correlation_id propagates
- [ ] Verify streaming path has a correlation_id (header + metadata)

### DETS Correctness (No Optimization)
- [ ] Crash after reserve, confirm DETS entry persists and orphan cleanup runs on next boot
- [ ] Crash after activate, confirm DETS entry persists and stale processes are cleaned
- [ ] Verify `:rogue_cleanup` behavior does not break current persistence guarantees

### adapter_env
- [ ] Configure process profile pool
- [ ] Verify Python worker has `OPENBLAS_NUM_THREADS=1` in environment
- [ ] Run NumPy workload, verify single-threaded execution
- [ ] Verify system-level thread limits from `Snakepit.Application` are preserved when `adapter_env` is set
