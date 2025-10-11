# gRPC Implementation Status and Completion Guide

## Overview

The Snakepit gRPC implementation is partially complete. While the Python gRPC server is fully functional and the Elixir workers can start and connect to it, the actual RPC calls are not being made. Instead, the client returns hardcoded placeholder responses.

## Current Implementation Status

### ✅ Complete Components

1. **Python gRPC Server Infrastructure** (`priv/python/grpc_server.py`)
   - Server framework and adapter loading implemented
   - Variable management methods implemented
   - ❌ **CRITICAL**: `ExecuteTool` and `ExecuteStreamingTool` return UNIMPLEMENTED errors
   - Requires implementation of tool execution logic

2. **Protocol Buffers** (`priv/proto/snakepit_bridge.proto`)
   - Complete service definition
   - All message types defined
   - Compiled to both Python and Elixir

3. **Worker Infrastructure** 
   - `lib/snakepit/grpc_worker.ex` - Manages Python process lifecycle
   - `lib/snakepit/adapters/grpc_python.ex` - Adapter implementation
   - Workers start successfully and maintain connections

### ❌ Incomplete Components

1. **Elixir gRPC Client Implementation**

   **File**: `lib/snakepit/grpc/client.ex`
   
   **Issue**: The `execute_tool/5` function returns a hardcoded response:
   ```elixir
   # Line 133
   {:ok, %{success: true, result: %{}, error_message: ""}}
   ```
   
   This should be making an actual gRPC call to the Python server.

2. **Missing ClientImpl Methods**

   **File**: `lib/snakepit/grpc/client_impl.ex`
   
   **Issue**: The module exists but doesn't implement the required methods:
   - `execute_tool/5`
   - `execute_streaming_tool/5`
   - Other service methods

## How to Complete the Implementation

### Step 0: Implement Python Server Tool Execution (CRITICAL)

The Python server currently raises UNIMPLEMENTED errors for tool execution. This must be fixed first.

**File**: `priv/python/grpc_server.py`

Update the `BridgeServiceServicer` class:

```python
@grpc_error_handler
async def ExecuteTool(self, request, context):
    """Execute a tool with an ephemeral session context."""
    logger.info(f"ExecuteTool: {request.tool_name} for session {request.session_id}")
    
    try:
        # Create ephemeral context for this request
        session_context = SessionContext(self.elixir_stub, request.session_id)
        
        # Create adapter instance for this request
        adapter = self.adapter_class()
        adapter.set_session_context(session_context)
        
        # Initialize adapter if needed
        if hasattr(adapter, 'initialize'):
            await adapter.initialize()
        
        # Execute the tool
        if hasattr(adapter, 'execute_tool'):
            result = await adapter.execute_tool(
                tool_name=request.tool_name,
                arguments=dict(request.arguments),
                context=session_context
            )
            
            # Build response
            response = pb2.ExecuteToolResponse()
            response.success = True
            response.result_json = json.dumps(result)
            return response
        else:
            # Tool execution not implemented in adapter
            context.set_code(grpc.StatusCode.UNIMPLEMENTED)
            context.set_details(f'Tool execution not implemented in adapter')
            return pb2.ExecuteToolResponse()
            
    except Exception as e:
        logger.error(f"ExecuteTool failed: {e}", exc_info=True)
        response = pb2.ExecuteToolResponse()
        response.success = False
        response.error_message = str(e)
        return response
```

For streaming:
```python
@grpc_error_handler
async def ExecuteStreamingTool(self, request, context):
    """Execute a streaming tool."""
    logger.info(f"ExecuteStreamingTool: {request.tool_name} for session {request.session_id}")
    
    try:
        session_context = SessionContext(self.elixir_stub, request.session_id)
        adapter = self.adapter_class()
        adapter.set_session_context(session_context)
        
        if hasattr(adapter, 'execute_streaming_tool'):
            async for chunk in adapter.execute_streaming_tool(
                tool_name=request.tool_name,
                arguments=dict(request.arguments),
                context=session_context
            ):
                response = pb2.ToolChunk()
                response.chunk_data = json.dumps(chunk)
                yield response
        else:
            context.set_code(grpc.StatusCode.UNIMPLEMENTED)
            context.set_details('Streaming not implemented in adapter')
    except Exception as e:
        logger.error(f"ExecuteStreamingTool failed: {e}", exc_info=True)
        # For streaming, we need to abort the stream
        context.abort(grpc.StatusCode.INTERNAL, str(e))
```

### Step 1: Implement the gRPC Client Calls (Refined)

The implementation should go in `client_impl.ex` with proper delegation from `client.ex`.

**File**: `lib/snakepit/grpc/client_impl.ex` (add new function)

```elixir
# Use the generated stub from snakepit_bridge.pb.ex
alias Snakepit.Bridge.BridgeService.Stub

def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  # Use the Serialization module for proper encoding
  proto_params =
    Enum.into(parameters, %{}, fn {k, v} ->
      # Assuming a helper to infer type for Any encoding
      {:ok, any_value, _binary_data} = Snakepit.Bridge.Serialization.encode_any(v, infer_type(v))
      proto_any = %Google.Protobuf.Any{type_url: any_value.type_url, value: any_value.value}
      {to_string(k), proto_any}
    end)

  request = Snakepit.Bridge.ExecuteToolRequest.new(
    session_id: session_id,
    tool_name: tool_name,
    parameters: proto_params
  )

  timeout = opts[:timeout] || @default_timeout

  case Stub.execute_tool(channel, request, timeout: timeout) do
    {:ok, response, _headers} ->
      handle_tool_response(response)
    {:ok, response} -> # Handle cases where headers are omitted
      handle_tool_response(response)
    {:error, reason} ->
      {:error, reason}
  end
end

defp handle_tool_response(%{success: true, result: any_result}) do
  # Decode the google.protobuf.Any response
  {:ok, decoded_result} = Snakepit.Bridge.Serialization.decode_any(%{
    type_url: any_result.type_url, 
    value: any_result.value
  })
  {:ok, %{success: true, result: decoded_result}}
end

defp handle_tool_response(%{success: false, error_message: error}) do
  {:error, error}
end
```

**File**: `lib/snakepit/grpc/client.ex` (update to delegate)

```elixir
def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  # Delegate to the real implementation
  Snakepit.GRPC.ClientImpl.execute_tool(channel, session_id, tool_name, parameters, opts)
end
```

### Step 2: Generate Elixir gRPC Stubs

The Elixir gRPC stubs need to be properly generated from the proto file:

1. Ensure the proto file is compiled with the Elixir gRPC plugin:
   ```bash
   protoc --elixir_out=plugins=grpc:./lib/snakepit/grpc \
          --proto_path=./priv/proto \
          snakepit_bridge.proto
   ```

2. This should generate:
   - `lib/snakepit/grpc/snakepit_bridge_pb.ex` (message definitions)
   - `lib/snakepit/grpc/snakepit_bridge_grpc_pb.ex` (service stubs)

### Step 3: Update the GRPCWorker

Modify `lib/snakepit/grpc_worker.ex` to use the proper stub module:

```elixir
def handle_call({:execute, command, args, timeout}, _from, state) do
  # Use the generated stub module
  stub = Snakepit.Grpc.Snakepit.Bridge.BridgeService.Stub
  
  request = Snakepit.Grpc.Snakepit.Bridge.ExecuteToolRequest.new(
    session_id: state.session_id,
    tool_name: command,
    arguments: encode_arguments(args)
  )

  case stub.execute_tool(state.connection, request, timeout: timeout) do
    {:ok, response} ->
      result = decode_response(response)
      {:reply, {:ok, result}, state}
    
    {:error, reason} ->
      {:reply, {:error, reason}, state}
  end
end
```

### Step 4: Implement Streaming Support

For streaming operations, implement the streaming stub calls:

```elixir
def handle_call({:execute_stream, command, args, callback_fn, timeout}, _from, state) do
  request = Snakepit.Grpc.Snakepit.Bridge.ExecuteStreamingToolRequest.new(
    session_id: state.session_id,
    tool_name: command,
    arguments: encode_arguments(args)
  )

  stream = stub.execute_streaming_tool(state.connection, request, timeout: timeout)
  
  # Process stream chunks
  spawn_link(fn ->
    Enum.each(stream, fn
      {:ok, chunk} ->
        decoded = decode_chunk(chunk)
        callback_fn.(decoded)
      
      {:error, reason} ->
        callback_fn.({:error, reason})
    end)
  end)
  
  {:reply, :ok, state}
end
```

### Step 5: Handle Variable Operations

Implement the variable management operations in `lib/snakepit/grpc/client_impl.ex`:

```elixir
def get_variable(channel, session_id, identifier) do
  request = Snakepit.Grpc.Snakepit.Bridge.GetVariableRequest.new(
    session_id: session_id,
    variable_identifier: identifier
  )
  
  case stub.get_variable(channel, request) do
    {:ok, response} ->
      {:ok, decode_variable(response.variable)}
    {:error, reason} ->
      {:error, reason}
  end
end
```

### Step 6: Update Configuration

Ensure the gRPC configuration properly initializes the channel:

```elixir
# In lib/snakepit/grpc_worker.ex init/1
def init(opts) do
  # ...existing code...
  
  # Create gRPC channel with proper options
  channel_opts = [
    interceptors: [GRPC.Client.Interceptors.Logger],
    codec: GRPC.Codec.Proto
  ]
  
  {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", channel_opts)
  
  # ...rest of init...
end
```

## Testing the Complete Implementation

1. **Unit Tests**: Create tests for each gRPC operation:
   ```elixir
   test "execute_tool makes proper gRPC call" do
     {:ok, channel} = GRPC.Stub.connect("localhost:50051")
     {:ok, result} = Client.execute_tool(channel, "session_1", "ping", %{message: "test"})
     assert result["message"] == "pong: test"
   end
   ```

2. **Integration Tests**: Test the full flow from Snakepit API to Python execution:
   ```elixir
   test "full execution flow" do
     {:ok, result} = Snakepit.execute("echo", %{data: "test"})
     assert result["echoed"]["data"] == "test"
   end
   ```

3. **Streaming Tests**: Verify streaming operations work correctly:
   ```elixir
   test "streaming execution" do
     {:ok, stream} = Snakepit.execute_stream("stream_progress", %{steps: 5})
     chunks = Enum.to_list(stream)
     assert length(chunks) == 5
   end
   ```

## Additional Recommendations

1. **Error Handling**: Implement proper error mapping from gRPC status codes to Elixir errors
2. **Reconnection Logic**: Add automatic reconnection when the Python server restarts (consider exponential backoff)
3. **Metrics**: Add telemetry events for gRPC call performance monitoring (latency, success/error rates, payload sizes)
4. **Circuit Breaker**: Implement circuit breaker pattern for failing workers to prevent cascading failures
5. **Connection Pooling**: Consider using a connection pool for the gRPC channels in high-throughput scenarios
6. **Context Propagation**: For distributed tracing (e.g., with OpenTelemetry), propagate trace IDs and context via gRPC metadata

## Summary

The gRPC bridge requires implementation on **both sides**:

### Python Side (CRITICAL)
- The `ExecuteTool` and `ExecuteStreamingTool` methods in `grpc_server.py` currently return UNIMPLEMENTED errors
- These must be implemented to actually call the adapter's tool execution methods

### Elixir Side
- The client is returning hardcoded responses instead of making real RPC calls
- Proper gRPC stubs need to be generated and integrated

## Revised Action Plan

1. **Implement Server Logic**: Implement the `ExecuteTool` and `ExecuteStreamingTool` methods in `priv/python/grpc_server.py`
2. **Implement Client Logic**: Implement the corresponding `execute_tool` and `execute_streaming_tool` functions in `lib/snakepit/grpc/client_impl.ex`, ensuring proper `Any` encoding/decoding
3. **Connect Client Facade**: Update `lib/snakepit/grpc/client.ex` to delegate calls to `ClientImpl` instead of returning mock data
4. **Integrate with Worker**: Ensure `lib/snakepit/grpc_worker.ex` correctly calls the new client functions
5. **Write Integration Tests**: Create tests that cover the full Elixir -> Python -> Elixir round trip for both unary and streaming calls
6. **Production Hardening**: Implement the additional recommendations, starting with error handling and metrics

With these changes implemented on both the Python and Elixir sides, the Snakepit gRPC bridge will be fully functional and production-ready.