# gRPC Integration Quick Reference

## Current State Summary

### What Works ✅
- Protocol buffer definitions complete
- Python gRPC server fully implemented
- Elixir worker/adapter structure ready
- Documentation and examples complete

### What's Missing ❌
- Pool manager doesn't know about GRPCWorker
- No actual gRPC client calls (only placeholders)
- Streaming API not exposed in public interface
- No Elixir protobuf code generation

## Critical Integration Points

### 1. Worker Type Selection (HIGHEST PRIORITY)

**File**: `lib/snakepit/pool/pool.ex`

```elixir
# Current (always uses standard worker):
defp start_worker(worker_id) do
  Worker.Starter.start_link(worker_id: worker_id)
end

# Needed:
defp start_worker(worker_id) do
  adapter = Application.get_env(:snakepit, :adapter_module)
  
  worker_module = if adapter.uses_grpc?() do
    GRPCWorker
  else
    Worker
  end
  
  worker_module.start_link(id: worker_id, adapter: adapter)
end
```

### 2. Public API Streaming Methods

**File**: `lib/snakepit.ex`

```elixir
# Add these functions:
def execute_stream(command, args, callback, opts \\ [])
def execute_in_session_stream(session_id, command, args, callback, opts \\ [])
```

### 3. gRPC Client Implementation

**File**: `lib/snakepit/adapters/grpc_python.ex`

Replace placeholder functions:
```elixir
# Current:
defp make_grpc_call(_channel, _method, _request) do
  {:error, "gRPC client not implemented yet"}
end

# Needed:
def grpc_execute(connection, command, args, timeout) do
  Snakepit.GRPC.Client.execute(connection.channel, command, args, timeout)
end
```

### 4. Pool Request Routing

**File**: `lib/snakepit/pool/pool.ex`

```elixir
# Add worker type detection:
defp execute_on_worker(worker_pid, command, args, timeout) do
  case get_worker_type(worker_pid) do
    :grpc -> GRPCWorker.execute(worker_pid, command, args, timeout)
    :standard -> Worker.execute(worker_pid, command, args, timeout)
  end
end
```

## Implementation Checklist

### Day 1: Foundation (4-6 hours)
- [ ] Generate Elixir protobuf code
- [ ] Create Snakepit.GRPC.Client module
- [ ] Update GRPCPython adapter to use real client
- [ ] Add `uses_grpc?/0` to adapter behavior

### Day 2: Integration (4-6 hours)
- [ ] Update Pool to support worker type selection
- [ ] Update WorkerSupervisor for dynamic worker type
- [ ] Add streaming methods to public API
- [ ] Fix GRPCWorker initialization

### Day 3: Testing & Polish (2-4 hours)
- [ ] Integration tests for gRPC execution
- [ ] Streaming tests with callbacks
- [ ] Performance benchmarks
- [ ] Error handling improvements

## Key Files to Modify

1. **Pool Manager** (`lib/snakepit/pool/pool.ex`)
   - Add worker type detection
   - Support streaming execution
   - Route requests to appropriate worker type

2. **Worker Supervisor** (`lib/snakepit/pool/worker_supervisor.ex`)
   - Dynamic worker module selection
   - Pass adapter to worker initialization

3. **Public API** (`lib/snakepit.ex`)
   - Add `execute_stream/4`
   - Add `execute_in_session_stream/5`
   - Check adapter capabilities

4. **gRPC Adapter** (`lib/snakepit/adapters/grpc_python.ex`)
   - Remove placeholder implementations
   - Use real gRPC client
   - Implement `uses_grpc?/0`

5. **gRPC Worker** (`lib/snakepit/grpc_worker.ex`)
   - Fix server startup
   - Proper connection initialization
   - Health check implementation

## Testing the Integration

### Quick Smoke Test
```elixir
# Configure gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

# Test basic execution
{:ok, result} = Snakepit.execute("ping", %{})

# Test streaming
Snakepit.execute_stream("ping_stream", %{count: 3}, fn chunk ->
  IO.inspect(chunk)
end)
```

### Verify Worker Type
```elixir
# Check if pool created correct worker type
workers = Registry.select(Snakepit.Pool.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
Enum.each(workers, fn pid ->
  IO.puts("Worker: #{inspect(Process.info(pid, :registered_name))}")
end)
```

## Common Pitfalls to Avoid

1. **Don't break existing workers** - Use feature detection, not hard switches
2. **Handle missing gRPC gracefully** - Check if GRPC module is loaded
3. **Preserve pool semantics** - GRPCWorker should behave like Worker from pool's perspective
4. **Test concurrent streams** - Ensure multiple streams can run simultaneously
5. **Monitor port allocation** - Prevent port conflicts with proper range management

## Success Indicators

1. `mix test` passes with both adapter types
2. Streaming demo runs without errors
3. Can switch adapters at runtime
4. Performance benchmarks show gRPC benefits
5. Health checks report accurate status

---

**Remember**: The architecture is solid. You're just connecting pipes that already exist.