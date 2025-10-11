# gRPC Bridge Redesign - Simple & Effective

## Overview

Replace the current stdin/stdout + MessagePack approach with a simple gRPC-based architecture that delivers the core benefits without over-engineering.

**Philosophy**: Build a functional race car, not a production Lexus. Get the essential streaming and performance benefits with minimal complexity.

## Problem Statement

Current architecture limitations:
- **No streaming**: Can't stream ML inference results, large datasets, or real-time updates
- **Blocking I/O**: Each request blocks until complete response
- **Manual protocol**: Hand-rolled 4-byte headers + JSON/MessagePack encoding
- **Port fragility**: stdin/stdout pipes can break, hard to debug
- **No multiplexing**: One request at a time per worker

## Solution: Simple gRPC Bridge

### Core Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Elixir App    │    │  gRPC Server    │    │ External Process│
│                 │◄──►│   (Worker)      │◄──►│  (Python/JS)    │
│ SnakepitClient  │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │              HTTP/2 + Protobuf               │
         │                       │                       │
    Pool Manager            gRPC Bridge              User Code
```

### Protocol Definition (Simple)

```protobuf
// snakepit.proto
syntax = "proto3";
package snakepit;

service SnakepitBridge {
  // Simple request/response (existing functionality)
  rpc Execute(ExecuteRequest) returns (ExecuteResponse);
  
  // Server streaming (new: progressive results)
  rpc ExecuteStream(ExecuteRequest) returns (stream StreamResponse);
  
  // Session management
  rpc ExecuteInSession(SessionRequest) returns (ExecuteResponse);
  rpc ExecuteInSessionStream(SessionRequest) returns (stream StreamResponse);
  
  // Health check
  rpc Health(HealthRequest) returns (HealthResponse);
}

message ExecuteRequest {
  string command = 1;
  map<string, bytes> args = 2;  // Use bytes for flexibility
  int32 timeout_ms = 3;
}

message ExecuteResponse {
  bool success = 1;
  map<string, bytes> result = 2;
  string error = 3;
  int64 timestamp = 4;
}

message StreamResponse {
  bool is_final = 1;
  map<string, bytes> chunk = 2;
  string error = 3;
  int64 timestamp = 4;
}

message SessionRequest {
  string session_id = 1;
  string command = 2;
  map<string, bytes> args = 3;
  int32 timeout_ms = 4;
}

message HealthRequest {}

message HealthResponse {
  bool healthy = 1;
  string worker_id = 2;
  int64 uptime_ms = 3;
}
```

## Implementation Plan

### Phase 1: Basic gRPC Bridge (2-3 days)

**Elixir Side:**
```elixir
# lib/snakepit/grpc_worker.ex
defmodule Snakepit.GRPCWorker do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  def execute(worker, command, args, timeout \\ 30_000) do
    GenServer.call(worker, {:execute, command, args, timeout})
  end
  
  def execute_stream(worker, command, args, callback) do
    GenServer.call(worker, {:execute_stream, command, args, callback})
  end
  
  # Simple gRPC client using grpc_cowboy or similar
  def init(opts) do
    port = opts[:port] || get_random_port()
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")
    start_external_process(port, opts[:adapter])
    {:ok, %{channel: channel, port: port}}
  end
  
  defp start_external_process(port, adapter) do
    # Start Python/JS process with gRPC server on specified port
    executable = adapter.executable_path()
    script = adapter.grpc_script_path()
    Port.open({:spawn_executable, executable}, [
      :binary, :exit_status,
      args: [script, "--port", to_string(port)]
    ])
  end
end
```

**Python Bridge (Simple):**
```python
# priv/python/grpc_bridge.py
import grpc
from concurrent import futures
import snakepit_pb2_grpc
import snakepit_pb2

class SnakepitBridgeServicer(snakepit_pb2_grpc.SnakepitBridgeServicer):
    def __init__(self):
        self.handlers = {
            'ping': self.handle_ping,
            'echo': self.handle_echo,
            'compute': self.handle_compute,
        }
    
    def Execute(self, request, context):
        handler = self.handlers.get(request.command)
        if not handler:
            return snakepit_pb2.ExecuteResponse(
                success=False,
                error=f"Unknown command: {request.command}"
            )
        
        try:
            result = handler(request.args)
            return snakepit_pb2.ExecuteResponse(
                success=True,
                result=result,
                timestamp=time.time_ns()
            )
        except Exception as e:
            return snakepit_pb2.ExecuteResponse(
                success=False,
                error=str(e),
                timestamp=time.time_ns()
            )
    
    def ExecuteStream(self, request, context):
        # Simple streaming example
        handler = self.handlers.get(request.command)
        if not handler:
            yield snakepit_pb2.StreamResponse(
                is_final=True,
                error=f"Unknown command: {request.command}"
            )
            return
        
        try:
            # Stream results in chunks
            for chunk in handler(request.args, streaming=True):
                yield snakepit_pb2.StreamResponse(
                    is_final=False,
                    chunk=chunk,
                    timestamp=time.time_ns()
                )
            
            # Final response
            yield snakepit_pb2.StreamResponse(
                is_final=True,
                timestamp=time.time_ns()
            )
        except Exception as e:
            yield snakepit_pb2.StreamResponse(
                is_final=True,
                error=str(e),
                timestamp=time.time_ns()
            )

def serve(port):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=1))
    snakepit_pb2_grpc.add_SnakepitBridgeServicer_to_server(
        SnakepitBridgeServicer(), server
    )
    listen_addr = f'[::]:{port}'
    server.add_insecure_port(listen_addr)
    server.start()
    server.wait_for_termination()

if __name__ == '__main__':
    import sys
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 50051
    serve(port)
```

### Phase 2: Streaming Features (1-2 days)

**Real-time ML Inference:**
```python
def handle_ml_inference_stream(self, args, streaming=True):
    model = load_model(args['model_path'])
    data_stream = args['data_stream']
    
    for batch in data_stream:
        predictions = model.predict(batch)
        yield {'predictions': predictions, 'batch_id': batch['id']}
```

**Progressive Data Processing:**
```python
def handle_large_dataset_stream(self, args, streaming=True):
    dataset_path = args['dataset_path'] 
    chunk_size = args.get('chunk_size', 1000)
    
    for chunk in read_dataset_chunks(dataset_path, chunk_size):
        processed = process_chunk(chunk)
        yield {'processed_chunk': processed, 'progress': chunk.progress}
```

### Phase 3: Session Support (1 day)

Simple session management using the existing session store:

```elixir
def execute_in_session(worker, session_id, command, args) do
  # Same session affinity logic as before
  # But using gRPC calls instead of stdin/stdout
  GenServer.call(worker, {:execute_session, session_id, command, args})
end
```

## Benefits Over Current Approach

### Immediate Wins
- **Native streaming**: ML inference results, progressive processing
- **HTTP/2 multiplexing**: Multiple concurrent requests per worker
- **Better error handling**: Rich gRPC status codes vs custom JSON
- **Auto-generated clients**: No manual protocol implementation
- **Built-in compression**: gRPC handles efficiently

### Performance Improvements
- **No 4-byte headers**: Protocol buffers handle framing
- **Binary by default**: More efficient than JSON, comparable to MessagePack
- **Connection reuse**: HTTP/2 vs new Port per request
- **Backpressure**: Built-in flow control for streams

### Operational Benefits
- **Better debugging**: Standard gRPC tools, logs, metrics
- **Health checks**: Built-in health check RPC
- **Load balancing**: Can easily add load balancing later
- **Monitoring**: Standard gRPC observability tools

## Migration Strategy

### Phase 1: Parallel Implementation
- Keep existing Port-based workers running
- Add new gRPC workers alongside
- New `Snakepit.Adapters.GRPCPython` adapter

### Phase 2: Feature Parity + New Features
- All existing functionality works via gRPC
- Add streaming capabilities
- Performance testing vs current approach

### Phase 3: Deprecation
- Mark old adapters as deprecated
- Provide migration guide
- Remove old code in next major version

## Simple Implementation Checklist

### Minimal Viable Product (MVP)
- [ ] Protocol buffer definitions
- [ ] Basic Elixir gRPC client wrapper
- [ ] Python gRPC server with existing commands
- [ ] Health check implementation
- [ ] Basic streaming example (ping stream)
- [ ] Integration with existing pool manager

### Essential Features
- [ ] Session support via gRPC
- [ ] Error handling and timeouts
- [ ] ML inference streaming example
- [ ] Data processing streaming example
- [ ] Performance benchmarks vs current approach

### Nice-to-Have (Later)
- [ ] JavaScript gRPC bridge
- [ ] Connection pooling optimization
- [ ] Advanced streaming patterns
- [ ] Distributed worker deployment

## Dependencies

**Elixir:**
- `grpc` - gRPC client library
- `protobuf` - Protocol buffer support

**Python:**
- `grpcio` - gRPC server library
- `protobuf` - Protocol buffer support

**Build Tools:**
- `protoc` - Protocol buffer compiler
- `grpc_tools.protoc` - Python gRPC code generation

## Estimated Effort

**Total: 4-6 developer days**
- Protocol design: 0.5 days
- Basic gRPC bridge: 2-3 days  
- Streaming features: 1-2 days
- Session integration: 1 day
- Testing & docs: 1 day

## Success Metrics

- **Streaming capability**: Can stream ML inference results
- **Performance**: At least equivalent to MessagePack approach
- **Compatibility**: All existing functionality works
- **Simplicity**: Less code than current Port-based approach
- **Reliability**: Better error handling and debugging

---

**Bottom Line**: This gives us 80% of the benefits of a full gRPC architecture with 20% of the complexity. We get native streaming, better performance, and cleaner code without over-engineering.