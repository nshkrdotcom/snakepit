# gRPC Integration Implementation Context

## Overview

You are tasked with completing the gRPC streaming integration for Snakepit, an Elixir library that manages external process pools. The foundation is 90% complete - all components exist but need to be connected. This document provides full context for implementing the remaining integration.

## Current Situation

Snakepit currently uses stdin/stdout communication with external processes (Python, Node.js, etc.). A new gRPC-based communication protocol has been designed and partially implemented to enable:
- Native streaming for progressive results
- HTTP/2 multiplexing for concurrent requests  
- Better error handling and health checks
- Constant memory usage for large datasets

## What's Already Implemented

### 1. Protocol Definitions
**File**: `priv/proto/snakepit.proto`
- Complete protocol buffer definitions
- Service `SnakepitBridge` with 6 RPC methods
- Message types for streaming and sessions

### 2. Python gRPC Server
**File**: `priv/python/grpc_bridge.py`
- Fully functional gRPC server
- Streaming handlers for ML inference, data processing, log analysis
- Integration with existing command handlers
- Example implementations of all streaming patterns

### 3. Generated Python Code
**Files**: `priv/python/snakepit_bridge/grpc/snakepit_pb2.py`, `snakepit_pb2_grpc.py`
- Protocol buffer generated code
- Ready to use, no changes needed

### 4. Elixir Framework
**Files**: 
- `lib/snakepit/adapters/grpc_python.ex` - Adapter with gRPC interface (has placeholders)
- `lib/snakepit/grpc_worker.ex` - GenServer for gRPC connections (complete structure)

### 5. Documentation
**Files**:
- `docs/GRPC_INTEGRATION_PLAN.md` - Detailed technical plan
- `docs/GRPC_QUICK_REFERENCE.md` - Quick implementation guide
- `README_GRPC.md` - User documentation
- `docs/specs/grpc_streaming_examples.md` - Use cases and examples

## What Needs Implementation

### Critical Gap: Worker Type Selection

The main issue is that the pool manager (`lib/snakepit/pool/pool.ex`) always creates standard workers that use stdin/stdout. It needs to:
1. Detect when a gRPC adapter is configured
2. Create `GRPCWorker` instances instead of standard `Worker` instances
3. Route requests to the appropriate worker type

### Specific Tasks

#### 1. Generate Elixir gRPC Client Code
No Elixir client code has been generated from the protocol buffers yet. You need to:
```bash
# Install protoc-gen-elixir
mix escript.install hex protobuf

# Generate the code (add to Makefile)
protoc --proto_path=priv/proto \
       --elixir_out=lib/snakepit/grpc \
       --elixir_opt=package_prefix=Snakepit.Grpc \
       priv/proto/snakepit.proto
```

#### 2. Implement gRPC Client Module
Create `lib/snakepit/grpc/client.ex` to wrap the generated code. See `docs/GRPC_INTEGRATION_PLAN.md` Phase 1.2 for the complete implementation.

#### 3. Update Pool Manager
**File**: `lib/snakepit/pool/pool.ex`

Current code in `start_workers_concurrently/2`:
```elixir
# Always creates standard workers
{Worker.Starter, worker_id: worker_id}
```

Needs to become:
```elixir
adapter = Application.get_env(:snakepit, :adapter_module)
worker_module = determine_worker_module(adapter)
{worker_module, id: worker_id, adapter: adapter}
```

See `docs/GRPC_INTEGRATION_PLAN.md` Phase 3.1 for complete implementation.

#### 4. Update Worker Supervisor  
**File**: `lib/snakepit/pool/worker_supervisor.ex`

Add logic to `start_worker/1` to choose between `Worker` and `GRPCWorker` based on adapter.

#### 5. Complete gRPC Adapter
**File**: `lib/snakepit/adapters/grpc_python.ex`

Replace all placeholder functions that return `{:error, "not implemented"}` with actual implementations that use the gRPC client. Key functions:
- `grpc_execute/4` 
- `grpc_execute_stream/5`
- `init_grpc_connection/1`

#### 6. Expose Streaming API
**File**: `lib/snakepit.ex`

Add public functions:
- `execute_stream/4` - For streaming execution
- `execute_in_session_stream/5` - For session-based streaming

These should check if the adapter supports gRPC before delegating to the pool.

#### 7. Fix GRPCWorker Initialization
**File**: `lib/snakepit/grpc_worker.ex`

The current `init/1` has issues:
- Uses wrong method to start external process
- Doesn't properly wait for gRPC server startup
- Has placeholder health check implementation

See `docs/GRPC_INTEGRATION_PLAN.md` Phase 5.1 for the corrected implementation.

## Architecture Context

### Current Flow (stdin/stdout)
```
Snakepit.execute/3 
→ Pool.execute/3 
→ Worker.execute/4 
→ Port.command (stdin)
→ External process
← Port message (stdout)
← Decoded response
```

### Target Flow (gRPC)
```
Snakepit.execute/3
→ Pool.execute/3
→ [NEW: Check worker type]
→ GRPCWorker.execute/4
→ GRPC.Client.execute/4
→ gRPC server (Python)
← Protobuf response
← Decoded result
```

### Key Design Principles

1. **Backward Compatibility**: Existing stdin/stdout workers must continue working
2. **Adapter Pattern**: Use adapter's `uses_grpc?/0` to determine worker type
3. **Transparent to Pool**: Pool shouldn't care about worker implementation details
4. **Progressive Enhancement**: Streaming is optional - only available with gRPC

## Testing Your Implementation

### 1. Basic Functionality Test
```elixir
# Configure gRPC adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
{:ok, _} = Application.ensure_all_started(:snakepit)

# Should work
{:ok, result} = Snakepit.execute("ping", %{})
```

### 2. Streaming Test
```elixir
# Should stream results
Snakepit.execute_stream("ping_stream", %{count: 5}, fn chunk ->
  IO.inspect(chunk, label: "Chunk")
end)
```

### 3. Worker Type Verification
```elixir
# Check that GRPCWorker was created
workers = Registry.select(Snakepit.Pool.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
# Should see GRPCWorker PIDs, not Worker PIDs
```

### 4. Run Existing Tests
```bash
# All existing tests should still pass
mix test

# Run the gRPC streaming demo
elixir examples/grpc_streaming_demo.exs
```

## Common Issues and Solutions

### Issue: "Generated gRPC code not found"
**Solution**: Run protobuf generation first (see task 1)

### Issue: Workers timeout during initialization
**Solution**: gRPC server needs time to start. Ensure proper sleep/retry in GRPCWorker.init

### Issue: "function uses_grpc?/0 undefined"
**Solution**: Add to adapter behavior or check with `function_exported?/3`

### Issue: Streaming functions not found
**Solution**: Make sure to add them to the public Snakepit module API

## Dependencies to Install

```elixir
# mix.exs already has these as optional:
{:grpc, "~> 0.8", optional: true},
{:protobuf, "~> 0.12", optional: true}

# Run: mix deps.get
```

```bash
# Python side already configured in setup.py
cd priv/python && pip install -e ".[grpc]"
```

## Success Criteria

1. **All existing tests pass** - No regression in current functionality
2. **gRPC adapter works** - Can execute basic commands via gRPC
3. **Streaming works** - Progressive results delivered via callbacks
4. **Demo runs** - `examples/grpc_streaming_demo.exs` executes successfully
5. **Performance improvement** - Benchmarks show benefits for streaming operations

## Where to Start

1. Read `docs/GRPC_QUICK_REFERENCE.md` for a day-by-day plan
2. Read `docs/GRPC_INTEGRATION_PLAN.md` sections for detailed implementations
3. Start with generating Elixir protobuf code
4. Implement the gRPC client module
5. Update pool manager to support worker type selection
6. Test basic execution before moving to streaming

## Additional Resources

- Main README: `README.md` - General Snakepit documentation
- gRPC Guide: `README_GRPC.md` - User guide for gRPC features
- Examples: `examples/grpc_streaming_demo.exs` - Working streaming examples
- Current Worker: `lib/snakepit/pool/worker.ex` - Reference for worker behavior
- Current Protocol: `lib/snakepit/bridge/protocol.ex` - How stdin/stdout currently works

## Questions to Keep in Mind

1. How does the pool currently select workers? (See `get_available_worker/1`)
2. Where does session affinity happen? (See `get_worker_for_session/2`)
3. How are workers restarted on failure? (See `Worker.Starter`)
4. What happens during pool shutdown? (See `handle_terminate/2`)

Remember: You're not redesigning anything. You're connecting components that already exist. The pool treats both worker types identically - the only difference is internal implementation.

Good luck! The hard architectural work is done. This is just plumbing.