## Snakepit Architecture Review

I'll review Snakepit as a production-ready library for enterprise MVP deployment.

---

## ✅ **Strengths**

### 1. **Solid OTP Foundation**
- Proper supervision tree (DynamicSupervisor → Worker.Starter → GRPCWorker)
- Process isolation with external OS processes
- Graceful shutdown with `trap_exit` and proper `terminate/2`
- Registry-based worker lookup (O(1) performance)

### 2. **Battle-Tested Patterns**
```elixir
# Good: Concurrent worker initialization with batching
defp start_workers_concurrently(pool_name, count, ...) do
  1..actual_count
  |> Enum.chunk_every(batch_size)  # Prevents fork bombs
  |> Enum.with_index()
  |> Enum.flat_map(fn {batch, batch_num} -> ... end)
end
```

### 3. **Advanced Features**
- Session affinity with ETS caching (performance fix noted in comments)
- Worker lifecycle management (TTL, max requests, memory thresholds)
- Dual worker profiles (process vs thread)
- Comprehensive process cleanup with `ProcessRegistry` + `ApplicationCleanup`

### 4. **Good Observability Hooks**
- Telemetry events throughout
- Detailed logging with context
- Diagnostic tools (`mix diagnose.scaling`, `mix snakepit.profile_inspector`)

---

## 🔴 **Critical Issues for Enterprise MVP**

### **1. Port Allocation Race Condition**

```elixir
# snakepit/adapters/grpc_python.ex:93
def get_port do
  # Port 0 = "OS, please assign me any available port"
  0
end
```

**Problem**: Every worker uses port `0` (OS-assigned ephemeral port). While this prevents collision, it creates **discovery problems**:

- Elixir doesn't know the port until after Python starts
- `wait_for_server_ready` parses stdout for `GRPC_READY:50123`
- **Fragile**: Stdout parsing can break if Python adds logging

**Enterprise Risk**: 🔴 **HIGH** - Flaky worker startup under load

**Fix**:
```elixir
defmodule Snakepit.PortAllocator do
  @moduledoc "Pre-allocates ports before worker spawn"
  use GenServer
  
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  
  def allocate_port do
    GenServer.call(__MODULE__, :allocate)
  end
  
  def release_port(port) do
    GenServer.cast(__MODULE__, {:release, port})
  end
  
  def init(_) do
    # Use a pool of pre-bound ports (50051-50151)
    {:ok, %{available: Enum.to_list(50051..50151), allocated: MapSet.new()}}
  end
  
  def handle_call(:allocate, _from, %{available: [port | rest]} = state) do
    case try_bind_port(port) do
      :ok -> 
        {:reply, {:ok, port}, %{state | available: rest, allocated: MapSet.put(state.allocated, port)}}
      {:error, :eaddrinuse} ->
        # Port still in TIME_WAIT, try next
        handle_call(:allocate, _from, %{state | available: rest})
    end
  end
  
  defp try_bind_port(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} -> 
        :gen_tcp.close(socket)
        :ok
      {:error, reason} -> 
        {:error, reason}
    end
  end
end
```

**Alternative** (simpler): Use Unix domain sockets instead of TCP ports:
```python
# grpc_server.py
server.add_insecure_port(f'unix:///tmp/snakepit_{worker_id}.sock')
```

---

### **2. No Health Check Before Marking Worker Ready**

```elixir
# snakepit/grpc_worker.ex:147
case wait_for_server_ready(state.server_port, 30000) do
  {:ok, actual_port} ->
    case state.adapter.init_grpc_connection(actual_port) do
      {:ok, connection} ->
        # Immediately notify pool - no health check!
        GenServer.call(state.pool_name, {:worker_ready, state.id}, 30_000)
```

**Problem**: Worker marked "ready" after TCP connection succeeds, but before verifying Python adapter is actually functional.

**Enterprise Risk**: 🟡 **MEDIUM** - Early requests can fail if Python still loading models

**Fix**:
```elixir
def handle_continue(:connect_and_wait, state) do
  case wait_for_server_ready(state.server_port, 30000) do
    {:ok, actual_port} ->
      case state.adapter.init_grpc_connection(actual_port) do
        {:ok, connection} ->
          # NEW: Verify adapter is actually ready
          case verify_adapter_ready(connection) do
            :ok ->
              GenServer.call(state.pool_name, {:worker_ready, state.id}, 30_000)
              # ... rest of code
            {:error, reason} ->
              {:stop, {:adapter_not_ready, reason}, state}
          end
      end
  end
end

defp verify_adapter_ready(connection) do
  # Ping the adapter to ensure it's responsive
  case Snakepit.GRPC.Client.ping(connection.channel, "ready_check") do
    {:ok, _} -> :ok
    error -> error
  end
end
```

---

### **3. Unbounded Queue Growth**

```elixir
# snakepit/pool/pool.ex:461
if current_queue_size >= pool_state.max_queue_size do
  # Pool saturated, reject immediately
  {:reply, {:error, :pool_saturated}, ...}
else
  # Queue the request
  request = {from, command, args, opts, System.monotonic_time()}
  new_queue = :queue.in(request, pool_state.request_queue)
```

**Problem**: `max_queue_size` defaults to 1000, but:
- No backpressure signal to callers
- Queued requests hold GenServer `from` references (memory leak if clients die)
- Timeout set per-request, but queue wait time not tracked

**Enterprise Risk**: 🟡 **MEDIUM** - Memory exhaustion under sustained overload

**Fix**:
```elixir
# Add queue age tracking
defmodule PoolState do
  defstruct [
    # ... existing fields
    :queue_age_histogram  # Track how long requests wait
  ]
end

# Before queueing
queue_depth = :queue.len(pool_state.request_queue)
estimated_wait = estimate_wait_time(pool_state)

if estimated_wait > pool_state.queue_timeout do
  # Proactively reject - queue too deep
  {:reply, {:error, {:queue_too_deep, estimated_wait}}, state}
else
  # Queue with backpressure signal
  :telemetry.execute([:snakepit, :pool, :queue_depth], %{depth: queue_depth + 1})
  # ... existing queue logic
end
```

---

### **4. Thread Profile Not Production Ready**

```elixir
# snakepit/worker_profile/thread.ex:20
@moduledoc """
## Status
**Phase 1 (Current)**: Stub implementation that returns `:not_implemented`
Full implementation planned for Phase 2-3 of v0.6.0 development.
```

**Problem**: Thread profile (`worker_profile: :thread`) is partially implemented but **not tested at scale**.

**Enterprise Risk**: 🔴 **HIGH** if you plan to use thread profile

**Recommendation**: 
- **For MVP**: Use `:process` profile only (battle-tested)
- **Clearly document** thread profile as experimental
- Add runtime validation:

```elixir
def init(opts) do
  pool_config = Keyword.get(opts, :pool_config, %{})
  
  if Map.get(pool_config, :worker_profile) == :thread do
    Logger.warning("""
    ⚠️  Thread profile is EXPERIMENTAL and not recommended for production.
    Use worker_profile: :process for production deployments.
    """)
    
    # Optional: Fail fast in prod
    if Mix.env() == :prod do
      {:stop, :thread_profile_not_production_ready}
    end
  end
  
  # ... rest of init
end
```

---

### **5. Session Affinity Cache Has No Expiration Visible to Caller**

```elixir
# snakepit/pool/pool.ex:803
defp get_preferred_worker(session_id, cache_table) do
  current_time = System.monotonic_time(:second)
  
  case :ets.lookup(cache_table, session_id) do
    [{^session_id, worker_id, expires_at}] when expires_at > current_time ->
      {:ok, worker_id}  # Cache hit
```

**Problem**: Session affinity cached for 60s, but:
- If worker dies, affinity entry persists until expiration
- Client will route to dead worker for up to 60s
- No cache invalidation on worker death

**Enterprise Risk**: 🟡 **MEDIUM** - Degraded UX after worker crashes

**Fix**:
```elixir
# In Pool.handle_info({:DOWN, _ref, :process, pid, reason}, state)
def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
  case Snakepit.Pool.Registry.get_worker_id_by_pid(pid) do
    {:ok, worker_id} ->
      # NEW: Invalidate affinity cache entries for this worker
      invalidate_affinity_cache(state.affinity_cache, worker_id)
      # ... existing code
  end
end

defp invalidate_affinity_cache(cache_table, dead_worker_id) do
  # Remove all cache entries pointing to dead worker
  match_spec = [{{:_, dead_worker_id, :_}, [], [true]}]
  deleted = :ets.select_delete(cache_table, match_spec)
  Logger.debug("Invalidated #{deleted} affinity cache entries for dead worker #{dead_worker_id}")
end
```

---

### **6. No Connection Pooling for gRPC Channels**

```elixir
# snakepit/grpc_worker.ex:184
def init(opts) do
  # Each worker creates its own channel
  case state.adapter.init_grpc_connection(actual_port) do
    {:ok, connection} ->
      # connection.channel stored per-worker
```

**Problem**: Each worker maintains 1 gRPC channel. For 100 workers:
- 100 TCP connections to central Elixir gRPC server (port 50051)
- Each connection has HTTP/2 overhead (flow control, keepalives)

**Enterprise Risk**: 🟢 **LOW** but inefficient

**Optimization** (not critical for MVP):
```elixir
defmodule Snakepit.GRPC.ChannelPool do
  @moduledoc "Shared gRPC channel pool to reduce connections"
  
  def checkout do
    # Use Poolboy or NimblePool for shared channels
    :poolboy.checkout(__MODULE__)
  end
  
  def checkin(channel) do
    :poolboy.checkin(__MODULE__, channel)
  end
end
```

**Note**: HTTP/2 multiplexing should handle this well, so **defer** unless you see connection exhaustion.

---

### **7. Process Cleanup Relies on String Matching**

```elixir
# snakepit/pool/process_registry.ex:432
defp cleanup_orphaned_processes(dets_table, current_beam_run_id, current_beam_os_pid) do
  # ...
  case Snakepit.ProcessKiller.get_process_command(info.process_pid) do
    {:ok, cmd} ->
      has_grpc_server = String.contains?(cmd, "grpc_server.py")
      has_old_run_id = String.contains?(cmd, "--snakepit-run-id #{info.beam_run_id}")
```

**Problem**: Identifying orphaned processes by parsing `ps` output and matching strings:
- Fragile if Python script name changes
- False positives if another app uses `grpc_server.py`
- False negatives if args truncated in `ps` output (common on some systems)

**Enterprise Risk**: 🟡 **MEDIUM** - Orphan leakage or false kills

**Fix**: Use process groups (PGID) for robust cleanup:

```elixir
# When spawning Python
port_opts = [
  :binary,
  {:args, [script | args]},
  {:cd, Path.dirname(script)},
  # NEW: Create process group
  {:process_group, worker_id_hash}  # Custom option via NIF
]
```

**Alternative** (simpler): Write PID to file and use file locking:

```python
# grpc_server.py
def write_pid_file(worker_id):
    pid_file = f'/tmp/snakepit_{worker_id}.pid'
    with open(pid_file, 'w') as f:
        f.write(str(os.getpid()))
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
```

```elixir
# Cleanup by reading PID files
defp cleanup_orphaned_processes do
  Path.wildcard("/tmp/snakepit_*.pid")
  |> Enum.each(fn pid_file ->
    pid = File.read!(pid_file) |> String.to_integer()
    if not_owned_by_current_beam?(pid) do
      ProcessKiller.kill_with_escalation(pid)
      File.rm(pid_file)
    end
  end)
end
```

---

## 🟡 **Design Concerns**

### **1. Heavy Use of GenServer Calls for Worker Operations**

```elixir
# Every execute goes through Pool GenServer
def handle_call({:execute, command, args, opts}, from, state) do
  # Pool is a serialization point
```

**Concern**: Pool GenServer is a **bottleneck** for high-throughput scenarios.

**Mitigation**: You've already added ETS caching for session affinity (good!), but could go further:

```elixir
# Optimize: Skip Pool for execute if we already have a worker
def execute_with_worker(worker_id, command, args, timeout) do
  # Direct call to worker, bypassing Pool GenServer
  Snakepit.GRPCWorker.execute(worker_id, command, args, timeout)
end

# Pool only for checkout/checkin
def execute(command, args, opts) do
  case fast_checkout_worker(opts) do
    {:ok, worker_id} ->
      try do
        execute_with_worker(worker_id, command, args, opts[:timeout])
      after
        fast_checkin_worker(worker_id)
      end
    {:error, :no_workers} ->
      # Fall back to Pool GenServer for queueing
      Pool.execute(command, args, opts)
  end
end
```

---

### **2. No Request Tracing/Correlation IDs**

**Missing**: Distributed tracing for debugging request flow through pool → worker → Python.

**Add**:
```elixir
def execute(command, args, opts) do
  correlation_id = Keyword.get_lazy(opts, :correlation_id, fn -> 
    UUID.uuid4() 
  end)
  
  Logger.metadata(correlation_id: correlation_id)
  
  args_with_trace = Map.put(args, :correlation_id, correlation_id)
  # ... execute with args_with_trace
end
```

Have Python log the same `correlation_id` for end-to-end tracing.

---

### **3. Config Validation Happens Too Late**

```elixir
# snakepit/application.ex:21
def start(_type, _args) do
  pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, false)
  # Config only validated when pool starts
```

**Problem**: Invalid config discovered at runtime (pool startup), not at compile time.

**Add**: Compile-time validation in `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  # Validate required configs
  unless Application.get_env(:snakepit, :adapter_module) do
    raise "Missing required config: :adapter_module"
  end
  
  pools = Application.get_env(:snakepit, :pools, [])
  Enum.each(pools, fn pool ->
    case Snakepit.Config.validate_pool_config(pool) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Invalid pool config: #{inspect(reason)}"
    end
  end)
end
```

---

## 📋 **MVP Readiness Checklist**

### **Must Fix Before MVP** (🔴 Critical)

1. ✅ **Port allocation race** (highest risk)
   - Either: Pre-allocate ports OR use Unix domain sockets
   
2. ✅ **Health check before marking ready**
   - Add `verify_adapter_ready/1` before notifying pool

3. ✅ **Document thread profile as experimental**
   - Add runtime warning/failure in prod

4. ⚠️ **Load test with expected traffic**
   - Validate pool size, queue depth, worker startup time
   - Measure memory usage under sustained load

### **Should Fix for Production** (🟡 Medium Priority)

5. ✅ **Invalidate affinity cache on worker death**
6. ✅ **Add request correlation IDs** (debugging)
7. ⚠️ **Improve orphan cleanup** (use PID files or process groups)
8. ⚠️ **Add comprehensive integration tests** (see below)

### **Nice to Have** (🟢 Low Priority)

9. ⚠️ **Connection pooling for gRPC** (defer)
10. ⚠️ **Pool GenServer optimization** (measure first)
11. ⚠️ **Compile-time config validation**

---

## 🧪 **Missing Test Coverage**

You need **integration tests** that simulate failure modes:

```elixir
defmodule Snakepit.IntegrationTest do
  use ExUnit.Case, async: false
  
  setup do
    # Start pool with small size for testing
    start_supervised!({Snakepit.Pool, size: 5})
    :ok
  end
  
  test "pool handles worker crash gracefully" do
    # Execute successful request
    {:ok, worker_id} = get_worker_id_for_test()
    
    # Kill worker process
    worker_pid = get_worker_pid(worker_id)
    Process.exit(worker_pid, :kill)
    
    # Next request should work (uses different worker)
    assert {:ok, _} = Snakepit.execute("ping", %{})
  end
  
  test "pool saturates gracefully under load" do
    # Saturate pool with slow requests
    tasks = for _ <- 1..100 do
      Task.async(fn ->
        Snakepit.execute("slow_command", %{sleep: 5000})
      end)
    end
    
    # Additional request should either queue or reject
    case Snakepit.execute("ping", %{}, timeout: 1000) do
      {:ok, _} -> :ok  # Queued and executed
      {:error, :pool_saturated} -> :ok  # Rejected
      {:error, :queue_timeout} -> :ok  # Timed out in queue
    end
  end
  
  test "session affinity maintained across requests" do
    session_id = "test_session_123"
    
    # First request establishes affinity
    {:ok, result1} = Snakepit.execute_in_session(session_id, "stateful_op", %{})
    worker_id_1 = extract_worker_id(result1)
    
    # Subsequent requests should use same worker
    {:ok, result2} = Snakepit.execute_in_session(session_id, "stateful_op", %{})
    worker_id_2 = extract_worker_id(result2)
    
    assert worker_id_1 == worker_id_2, "Session affinity broken"
  end
  
  test "orphaned Python processes cleaned up on restart" do
    # Start pool
    {:ok, pid} = start_supervised(Snakepit.Pool)
    
    # Get Python PIDs
    python_pids_before = get_python_pids()
    assert length(python_pids_before) > 0
    
    # Brutal kill of Elixir supervisor (simulate crash)
    Process.exit(pid, :kill)
    :timer.sleep(100)
    
    # Restart
    {:ok, _} = start_supervised(Snakepit.Pool)
    
    # Old Python processes should be dead
    python_pids_after = get_python_pids()
    
    # No orphans from previous run
    orphans = python_pids_before -- python_pids_after
    assert Enum.empty?(orphans), "Found #{length(orphans)} orphaned processes"
  end
end
```

---

## 🎯 **Final Verdict: MVP Ready?**

### **YES**, with caveats:

| Aspect | Status | Notes |
|--------|--------|-------|
| **Architecture** | ✅ Solid | Good OTP design, supervision tree looks correct |
| **Process Profile** | ✅ Production Ready | Battle-tested pattern, use this |
| **Thread Profile** | ❌ Experimental | Document clearly, disable in prod |
| **Worker Lifecycle** | ✅ Good | Cleanup logic is comprehensive |
| **Performance** | ⚠️ Unknown | **Must load test before MVP** |
| **Failure Recovery** | ⚠️ Good with Gaps | Fix port allocation + health check |
| **Observability** | ⚠️ Adequate | Add correlation IDs for debugging |
| **Documentation** | ✅ Excellent | Moduledocs are thorough |

### **Action Plan for MVP Launch**:

**Week 1** (Critical Fixes):
1. Fix port allocation (switch to port pool or Unix sockets)
2. Add health check before marking worker ready
3. Add runtime guard against thread profile in prod
4. Load test with 2x expected traffic

**Week 2** (Hardening):
5. Invalidate affinity cache on worker death
6. Add correlation ID tracking
7. Integration tests for failure modes
8. Document known limitations

**Week 3** (Monitoring):
9. Set up dashboards for pool metrics (queue depth, saturation, worker churn)
10. Alert on high queue depth or frequent worker crashes
11. Smoke test in staging environment

### **Known Limitations to Document**:

```markdown
## Known Limitations (v0.6.0)

- **Thread profile experimental**: Use `worker_profile: :process` for production
- **Port allocation**: Currently uses OS-assigned ephemeral ports (may cause discovery delays)
- **Session affinity cache**: 60s TTL not invalidated on worker death (may route to dead workers briefly)
- **No distributed support**: Single-node only (no Horde/pg2 integration)
- **Python 3.8+ required**: Earlier versions unsupported
```

---

## 💪 **You're the BEAM Warrior**

Your code shows **deep OTP knowledge**:
- Proper supervision strategies
- ETS for performance-critical paths
- Thoughtful comments about race conditions
- Defensive programming (trap_exit, safe_close_port, etc.)

The gaps are **normal for a WIP library**. Fix the critical 4 items above, load test thoroughly, and you'll have a solid MVP.

**Ship it** 🚀 (after those fixes). Then battle-test and iterate.
