# Snakepit gRPC Bridge Implementation Plan

## Executive Summary

This document provides a detailed implementation plan to complete the Snakepit gRPC bridge, enabling full bidirectional communication between Elixir and Python components. The implementation requires changes on both the Python server and Elixir client sides.

## 1. Current State Analysis

Based on the `mix demo.all` output and code inspection:

### What's Working
- Python gRPC servers start successfully
- Worker pool initialization completes
- Basic infrastructure for gRPC communication exists

### What's Not Working
- **Python Server**: `ExecuteTool` and `ExecuteStreamingTool` raise UNIMPLEMENTED errors
- **Elixir Client**: Returns hardcoded `{:ok, %{success: true, result: %{}, error_message: ""}}` 
- **Streaming**: Crashes with `CaseClauseError` due to mock response mismatch
- **All demo results**: Return nil or empty values

## 2. Implementation Tasks

### Task 1: Python Server Implementation

#### 1.1 Implement ExecuteTool Method

**File**: `priv/python/grpc_server.py`

**Implementation**:
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
        
        # Decode parameters from protobuf Any
        arguments = {}
        for key, any_msg in request.arguments.items():
            # Basic decoding - assumes JSON-encoded values for now
            if any_msg.type_url == "type.googleapis.com/google.protobuf.StringValue":
                arguments[key] = any_msg.value.decode('utf-8')
            else:
                # For complex types, use JSON decoding
                arguments[key] = json.loads(any_msg.value.decode('utf-8'))
        
        # Execute the tool
        if hasattr(adapter, 'execute_tool'):
            result = await adapter.execute_tool(
                tool_name=request.tool_name,
                arguments=arguments,
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

#### 1.2 Implement ExecuteStreamingTool Method

**Implementation**:
```python
@grpc_error_handler
async def ExecuteStreamingTool(self, request, context):
    """Execute a streaming tool."""
    logger.info(f"ExecuteStreamingTool: {request.tool_name} for session {request.session_id}")
    
    try:
        session_context = SessionContext(self.elixir_stub, request.session_id)
        adapter = self.adapter_class()
        adapter.set_session_context(session_context)
        
        # Decode parameters
        arguments = {}
        for key, any_msg in request.arguments.items():
            if any_msg.type_url == "type.googleapis.com/google.protobuf.StringValue":
                arguments[key] = any_msg.value.decode('utf-8')
            else:
                arguments[key] = json.loads(any_msg.value.decode('utf-8'))
        
        # Check if adapter supports streaming
        if hasattr(adapter, 'execute_streaming_tool'):
            async for chunk in adapter.execute_streaming_tool(
                tool_name=request.tool_name,
                arguments=arguments,
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
        context.abort(grpc.StatusCode.INTERNAL, str(e))
```

### Task 2: Elixir Client Implementation

#### 2.1 Implement execute_tool in ClientImpl

**File**: `lib/snakepit/grpc/client_impl.ex`

**Add these functions**:
```elixir
alias Snakepit.Bridge.BridgeService.Stub

def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  # For now, use JSON encoding for simplicity
  # Later can be enhanced with proper Any encoding
  proto_params = 
    Enum.into(parameters, %{}, fn {k, v} ->
      json_value = Jason.encode!(v)
      any_msg = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.protobuf.StringValue",
        value: json_value
      }
      {to_string(k), any_msg}
    end)

  request = Snakepit.Bridge.ExecuteToolRequest.new(
    session_id: session_id,
    tool_name: tool_name,
    arguments: proto_params
  )

  timeout = opts[:timeout] || 30_000

  case Stub.execute_tool(channel, request, timeout: timeout) do
    {:ok, %{success: true, result_json: result_json}, _headers} ->
      {:ok, Jason.decode!(result_json)}
    
    {:ok, %{success: true, result_json: result_json}} ->
      {:ok, Jason.decode!(result_json)}
    
    {:ok, %{success: false, error_message: error}} ->
      {:error, error}
    
    {:error, reason} ->
      {:error, reason}
  end
end

def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  proto_params = 
    Enum.into(parameters, %{}, fn {k, v} ->
      json_value = Jason.encode!(v)
      any_msg = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.protobuf.StringValue",
        value: json_value
      }
      {to_string(k), any_msg}
    end)

  request = Snakepit.Bridge.ExecuteToolRequest.new(
    session_id: session_id,
    tool_name: tool_name,
    arguments: proto_params
  )

  timeout = opts[:timeout] || 300_000

  # Return the stream directly
  Stub.execute_streaming_tool(channel, request, timeout: timeout)
end
```

#### 2.2 Update Client to Delegate

**File**: `lib/snakepit/grpc/client.ex`

**Replace the mock implementation**:
```elixir
def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
  Snakepit.GRPC.ClientImpl.execute_tool(channel, session_id, tool_name, parameters, opts)
end
```

### Task 3: Fix Streaming in GRPCPython Adapter

**File**: `lib/snakepit/adapters/grpc_python.ex`

**Update grpc_execute_stream**:
```elixir
def grpc_execute_stream(connection, command, args, callback_fn, timeout \\ 300_000) do
  Logger.info("[GRPCPython] grpc_execute_stream - command: #{command}, args: #{inspect(args)}, timeout: #{timeout}")

  unless grpc_available?() do
    Logger.error("[GRPCPython] gRPC not available")
    {:error, :grpc_not_available}
  else
    case Snakepit.GRPC.ClientImpl.execute_streaming_tool(
      connection.channel, 
      "default_session", 
      command, 
      args, 
      timeout: timeout
    ) do
      {:error, reason} ->
        {:error, reason}
      
      stream ->
        # Process the stream asynchronously
        Task.start(fn ->
          Enum.each(stream, fn
            {:ok, %{chunk_data: chunk_json}} ->
              decoded = Jason.decode!(chunk_json)
              callback_fn.(decoded)
            
            {:error, reason} ->
              callback_fn.({:error, reason})
          end)
        end)
        
        {:ok, :streaming}
    end
  end
end
```

### Task 4: Update GRPCWorker for Streaming

**File**: `lib/snakepit/grpc_worker.ex`

**Fix the execute_stream handler**:
```elixir
def handle_call({:execute_stream, command, args, callback_fn, timeout}, _from, state) do
  Logger.info("[GRPCWorker] handle_call execute_stream - command: #{command}, args: #{inspect(args)}")

  case state.adapter.grpc_execute_stream(state.connection, command, args, callback_fn, timeout) do
    {:ok, :streaming} ->
      new_state = update_stats(state, :success)
      {:reply, {:ok, :streaming}, new_state}

    {:error, reason} ->
      new_state = update_stats(state, :error)
      {:reply, {:error, reason}, new_state}
  end
end
```

### Task 5: Update ShowcaseAdapter for Streaming

**File**: `priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py`

**Add streaming support**:
```python
async def execute_streaming_tool(self, tool_name: str, arguments: Dict[str, Any], context):
    """Execute a streaming tool by delegating to the appropriate method."""
    if tool_name == "stream_progress":
        steps = arguments.get("steps", 10)
        for i in range(1, steps + 1):
            await asyncio.sleep(0.1)  # Simulate work
            yield {
                "step": i,
                "total": steps,
                "progress": int((i / steps) * 100),
                "message": f"Processing step {i}"
            }
    
    elif tool_name == "stream_fibonacci":
        count = arguments.get("count", 20)
        a, b = 0, 1
        for i in range(count):
            yield {"index": i, "value": a}
            a, b = b, a + b
            await asyncio.sleep(0.05)
    
    else:
        raise ValueError(f"Unknown streaming tool: {tool_name}")
```

## 3. Testing Strategy

### 3.1 Unit Tests

**Python Tests** (`test/python/test_grpc_server.py`):
```python
async def test_execute_tool():
    """Test ExecuteTool method with mock adapter."""
    servicer = BridgeServiceServicer(MockAdapter, "localhost:50051")
    request = pb2.ExecuteToolRequest(
        session_id="test_session",
        tool_name="ping",
        arguments={"message": encode_any("test")}
    )
    response = await servicer.ExecuteTool(request, None)
    assert response.success == True
    assert "pong" in response.result_json
```

**Elixir Tests** (`test/grpc/client_impl_test.exs`):
```elixir
test "execute_tool encodes and decodes correctly" do
  {:ok, channel} = create_mock_channel()
  
  # Mock the Stub to return a known response
  expect(Stub, :execute_tool, fn _channel, request, _opts ->
    assert request.tool_name == "echo"
    assert request.session_id == "test_session"
    
    {:ok, %{success: true, result_json: ~s({"echoed": {"test": "data"}})}}
  end)
  
  {:ok, result} = ClientImpl.execute_tool(channel, "test_session", "echo", %{test: "data"})
  assert result == %{"echoed" => %{"test" => "data"}}
end
```

### 3.2 Integration Tests

**File**: `test/integration/grpc_bridge_test.exs`

```elixir
defmodule Snakepit.Integration.GRPCBridgeTest do
  use ExUnit.Case

  setup do
    # Ensure the application is started
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :ok
  end

  test "full round-trip execution" do
    {:ok, result} = Snakepit.execute("ping", %{message: "integration test"})
    assert result["message"] == "pong: integration test"
    assert result["timestamp"] != nil
  end

  test "streaming execution" do
    {:ok, stream} = Snakepit.execute_stream("stream_fibonacci", %{count: 5})
    
    chunks = Enum.to_list(stream)
    assert length(chunks) == 5
    assert Enum.at(chunks, 0)["value"] == 0
    assert Enum.at(chunks, 1)["value"] == 1
    assert Enum.at(chunks, 4)["value"] == 3
  end

  test "error propagation" do
    {:error, reason} = Snakepit.execute("nonexistent_tool", %{})
    assert reason =~ "Unknown tool"
  end
end
```

## 4. Rollout Plan

### Phase 1: Core Implementation (2-3 days)
1. Implement Python server methods
2. Implement Elixir client methods
3. Fix streaming handlers
4. Run manual tests with showcase

### Phase 2: Testing (1-2 days)
1. Write and run unit tests
2. Write and run integration tests
3. Fix any discovered issues

### Phase 3: Documentation (1 day)
1. Update implementation status document
2. Add inline code documentation
3. Create usage examples

### Phase 4: Production Hardening (2-3 days)
1. Add proper error handling and retries
2. Implement telemetry/metrics
3. Add connection health monitoring
4. Performance optimization

## 5. Success Criteria

The implementation is successful when:

1. ✅ `mix demo.all` runs without errors
2. ✅ All demos display actual data (not nil/empty)
3. ✅ Streaming demos show multiple progress updates
4. ✅ Error demos properly catch and display errors
5. ✅ All tests pass
6. ✅ No hardcoded/mock responses remain in the data path

## 6. Risk Mitigation

### Technical Risks
1. **Protobuf Any encoding complexity**: Start with JSON encoding, optimize later
2. **Stream backpressure**: Implement buffering limits in streaming handlers
3. **Connection failures**: Add reconnection logic with exponential backoff

### Schedule Risks
1. **Unknown dependencies**: Time-boxed investigation phases
2. **Integration issues**: Daily integration tests during development

## 7. Future Enhancements

After core functionality is complete:

1. Binary serialization optimization for large payloads
2. Connection pooling for high-throughput scenarios
3. Distributed tracing with OpenTelemetry
4. Circuit breaker pattern for fault tolerance
5. Advanced monitoring and alerting

## Conclusion

This plan provides a clear path to complete the Snakepit gRPC bridge implementation. The phased approach ensures early validation of core functionality while building toward a production-ready system. With proper testing and documentation, the bridge will enable reliable, high-performance communication between Elixir and Python components.