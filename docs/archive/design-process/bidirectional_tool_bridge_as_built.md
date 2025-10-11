# Bidirectional Tool Bridge - As-Built Documentation

## Executive Summary

This document describes the as-built implementation of the bidirectional tool bridge between Elixir and Python in the Snakepit framework. The implementation enables seamless cross-language tool execution, allowing Python DSPy programs to transparently call Elixir functions and vice versa through a unified gRPC bridge.

### Implementation Status
- ✅ **Core Infrastructure**: Complete bidirectional gRPC communication
- ✅ **Tool Registry**: Dynamic tool discovery and registration
- ✅ **Python → Elixir**: Full implementation with transparent proxying
- ✅ **Elixir → Python**: Foundation ready, execution path implemented
- ⚠️ **Production Readiness**: Several challenges remain (detailed below)

## Architecture As-Built

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Elixir Side                              │
├─────────────────────────────────────────────────────────────────┤
│  Application.ex                                                 │
│    └── ToolRegistry (GenServer)                                │
│    └── SessionStore (ETS-backed)                               │
│                                                                 │
│  BridgeServer.ex (gRPC Service)                                │
│    ├── execute_tool/2         - Execute Python tools           │
│    ├── register_tools/2       - Register Python tools          │
│    ├── get_exposed_elixir_tools/2 - List Elixir tools         │
│    └── execute_elixir_tool/2  - Execute Elixir tools          │
│                                                                 │
│  ToolRegistry.ex                                                │
│    ├── InternalToolSpec (struct)                               │
│    ├── register_elixir_tool/4                                  │
│    ├── register_python_tool/4                                  │
│    └── execute_local_tool/3                                    │
└─────────────────────────────────────────────────────────────────┘
                            ▲ ▼ gRPC
┌─────────────────────────────────────────────────────────────────┐
│                        Python Side                              │
├─────────────────────────────────────────────────────────────────┤
│  grpc_server.py                                                │
│    └── BridgeServiceServicer                                   │
│        ├── ExecuteTool         - Handle tool execution         │
│        └── ExecuteStreamingTool - Handle streaming tools       │
│                                                                 │
│  session_context.py                                            │
│    ├── _load_elixir_tools()    - Auto-discover on init        │
│    ├── call_elixir_tool()      - Direct execution             │
│    ├── _create_tool_proxy()    - Dynamic proxy generation     │
│    └── elixir_tools (property) - Access to tool proxies       │
│                                                                 │
│  base_adapter.py                                               │
│    ├── @tool decorator         - Mark methods as tools        │
│    ├── get_tools()            - Tool discovery                │
│    └── register_with_session() - Auto-registration            │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow Implementation

#### 1. Tool Registration Flow (Python → Elixir)

```python
# Python adapter with @tool decorator
class MyAdapter(BaseAdapter):
    @tool(description="Process data")
    def process(self, data: str) -> dict:
        return {"processed": data}

# On adapter instantiation in grpc_server.py:
adapter = MyAdapter()
adapter.register_with_session(session_id, elixir_stub)
# → Sends RegisterToolsRequest with tool specifications
# → Elixir stores in ToolRegistry ETS table
```

#### 2. Tool Discovery Flow (Python ← Elixir)

```python
# In SessionContext.__init__:
self._load_elixir_tools()
# → Sends GetExposedElixirToolsRequest
# → Receives list of ToolSpec messages
# → Creates dynamic proxy functions
# → Stores in self._elixir_tools dict
```

#### 3. Tool Execution Flow (Python → Elixir)

```python
# Python code
ctx.call_elixir_tool("parse_json", json_string='{"test": true}')
# → Creates ExecuteElixirToolRequest
# → Serializes parameters as protobuf Any
# → Elixir BridgeServer.execute_elixir_tool/2 handles request
# → ToolRegistry.execute_local_tool/3 applies the function
# → Result serialized and returned
```

## Implementation Details

### 1. Protobuf Schema Extensions

Added to `snakepit_bridge.proto`:

```protobuf
// Tool Registration
rpc RegisterTools(RegisterToolsRequest) returns (RegisterToolsResponse);
rpc GetExposedElixirTools(GetExposedElixirToolsRequest) returns (GetExposedElixirToolsResponse);
rpc ExecuteElixirTool(ExecuteElixirToolRequest) returns (ExecuteElixirToolResponse);

message ToolRegistration {
  string name = 1;
  string description = 2;
  repeated ParameterSpec parameters = 3;
  map<string, string> metadata = 4;
  bool supports_streaming = 5;
}

message ExecuteElixirToolRequest {
  string session_id = 1;
  string tool_name = 2;
  map<string, google.protobuf.Any> parameters = 3;
  map<string, string> metadata = 4;
}
```

### 2. Elixir Implementation

#### ToolRegistry GenServer
- **State Storage**: ETS table `:snakepit_tool_registry`
- **Key Format**: `{session_id, tool_name}`
- **Value**: `InternalToolSpec` struct with metadata
- **Lifecycle**: Started in Application supervisor

#### BridgeServer Handlers
- **execute_tool/2**: Dispatches to local or remote tools
- **register_tools/2**: Batch registration from Python workers
- **get_exposed_elixir_tools/2**: Returns tools with `exposed_to_python: true`
- **execute_elixir_tool/2**: Executes local Elixir functions

#### Type Handling
- Parameters decoded from protobuf Any using JSON serialization
- Results encoded back to protobuf Any with type URL
- Metadata converted from atoms to strings for protobuf compatibility

### 3. Python Implementation

#### BaseAdapter Pattern
```python
class BaseAdapter:
    def get_tools(self) -> List[ToolRegistration]:
        # Discovers methods decorated with @tool
        # Extracts parameter info from function signatures
        # Returns protobuf ToolRegistration messages
    
    def register_with_session(self, session_id: str, stub):
        # Sends discovered tools to Elixir
        # Returns list of registered tool names
```

#### SessionContext Integration
```python
class SessionContext:
    def __init__(self, stub, session_id):
        # ... existing init ...
        self._elixir_tools = {}
        self._load_elixir_tools()  # Auto-discovery
    
    def call_elixir_tool(self, tool_name: str, **kwargs):
        # Direct execution with parameter serialization
        # Error handling and result deserialization
    
    @property
    def elixir_tools(self) -> Dict[str, Callable]:
        # Access to tool proxies
        # Each proxy is a Python callable
```

#### Dynamic Proxy Generation
```python
def _create_tool_proxy(self, tool_spec: ToolSpec):
    def proxy(**kwargs):
        return self.call_elixir_tool(tool_spec.name, **kwargs)
    
    # Preserve metadata
    proxy.__name__ = tool_spec.name
    proxy.__doc__ = tool_spec.description
    # Add parameter annotations from spec
    
    return proxy
```

## Current Challenges and Limitations

### 1. Serialization Complexity

**Challenge**: The current implementation uses JSON serialization wrapped in protobuf Any, which has limitations:
- Cannot handle binary data efficiently
- Complex types (e.g., numpy arrays) require custom serialization
- Type information is lost during round-trip

**Current Workaround**:
```python
# In encode_tool_result (Elixir)
case Jason.encode(value) do
  {:ok, json_string} -> 
    %Any{type_url: "type.googleapis.com/google.protobuf.StringValue", value: json_string}
  {:error, _} -> 
    %Any{type_url: "type.googleapis.com/google.protobuf.StringValue", value: inspect(value)}
end
```

**Impact**: Limits the types of data that can be passed between languages.

### 2. Metadata Encoding Issues

**Challenge**: Elixir atoms vs. Python strings in metadata cause encoding errors:
```elixir
# Error: :description is invalid for type :string
# Fixed by converting all atoms to strings:
metadata = Map.new(tool.metadata, fn {k, v} -> {to_string(k), to_string(v)} end)
```

**Impact**: Extra conversion overhead and potential for runtime errors.

### 3. Session Lifecycle Management

**Challenge**: Tools are scoped to sessions, but session cleanup is manual:
- No automatic cleanup when Python workers disconnect
- Orphaned tools remain in registry
- Session conflicts when reusing IDs

**Current State**: Relies on explicit cleanup calls.

### 4. Error Propagation

**Challenge**: Error messages lose context across language boundary:
```python
# Python sees generic error:
RuntimeError: Elixir tool execution failed: Tool execution failed: %ArgumentError{message: "..."}
```

**Impact**: Difficult debugging for end users.

### 5. Type Safety and Validation

**Challenge**: No compile-time type checking across languages:
- Parameter types are strings ("integer", "string", etc.)
- No automatic validation of parameter values
- Type mismatches detected only at runtime

**Current Implementation**: Basic runtime validation only.

### 6. Performance Considerations

**Challenge**: Each tool call involves:
1. Parameter serialization (Python → JSON → Protobuf)
2. gRPC network call (even for local tools)
3. ETS lookup in Elixir
4. Function execution
5. Result serialization (Elixir → JSON → Protobuf)

**Measured Overhead**: ~5-10ms per tool call on localhost.

### 7. Streaming Support

**Challenge**: Current implementation doesn't support streaming tools:
- `ExecuteElixirTool` returns single response
- No mechanism for progress updates
- Long-running tools block

**Status**: Foundation exists but not implemented.

### 8. Security Considerations

**Challenge**: No access control on tool execution:
- Any session can call any exposed tool
- No parameter sanitization
- No rate limiting

**Risk**: Potential for abuse in production environments.

## Production Readiness Checklist

### ✅ Completed
- [x] Basic bidirectional tool execution
- [x] Tool discovery and registration
- [x] Dynamic proxy generation
- [x] Session-scoped tool isolation
- [x] Example implementations

### ⚠️ Partially Complete
- [ ] Error handling (basic implementation, needs improvement)
- [ ] Type validation (strings only, no complex types)
- [ ] Performance optimization (no caching, connection pooling)

### ❌ Not Implemented
- [ ] Streaming tool support
- [ ] Security/access control
- [ ] Automatic session cleanup
- [ ] Tool versioning
- [ ] Metrics and monitoring
- [ ] Rate limiting
- [ ] Circuit breakers
- [ ] Comprehensive test suite

## Recommendations for Production Use

### 1. Immediate Priorities

**Type System Enhancement**:
```elixir
# Add type validation module
defmodule Snakepit.Bridge.TypeValidator do
  def validate_parameters(params, spec) do
    # Validate each parameter against its spec
    # Return {:ok, normalized} or {:error, details}
  end
end
```

**Session Cleanup**:
```elixir
# Add process monitoring
defmodule Snakepit.Bridge.SessionMonitor do
  use GenServer
  
  def monitor_session(session_id, pid) do
    # Link to Python worker process
    # Cleanup on disconnect
  end
end
```

### 2. Performance Improvements

**Connection Pooling**:
- Reuse gRPC channels between Python and Elixir
- Implement connection timeout and retry logic

**Caching Layer**:
- Cache tool metadata to avoid repeated lookups
- Cache frequently used tool results (with TTL)

### 3. Security Hardening

**Access Control**:
```elixir
defmodule Snakepit.Bridge.ToolPolicy do
  def can_execute?(session_id, tool_name, params) do
    # Check permissions
    # Validate parameters
    # Apply rate limits
  end
end
```

**Parameter Sanitization**:
- Validate all inputs before execution
- Limit parameter sizes
- Sanitize error messages

### 4. Monitoring and Observability

**Telemetry Integration**:
```elixir
:telemetry.execute(
  [:snakepit, :tool, :execute],
  %{duration: duration},
  %{tool_name: tool_name, session_id: session_id, success: success}
)
```

**Metrics to Track**:
- Tool execution count and latency
- Error rates by tool and session
- Active sessions and tools
- Parameter serialization time

## Testing Considerations

### Current Test Coverage
- ❌ No automated tests for tool bridge
- ✅ Manual testing via examples
- ⚠️ Basic integration testing only

### Recommended Test Suite

**Unit Tests**:
```elixir
# Test tool registration
test "register_elixir_tool/4 stores tool in registry" do
  ToolRegistry.register_elixir_tool("session1", "test_tool", &func/1, %{})
  assert {:ok, tool} = ToolRegistry.get_tool("session1", "test_tool")
  assert tool.name == "test_tool"
end
```

**Integration Tests**:
```python
# Test Python calling Elixir
def test_call_elixir_tool():
    ctx = SessionContext(stub, "test-session")
    result = ctx.call_elixir_tool("parse_json", json_string='{"test": true}')
    assert result["success"] == True
```

**Property-Based Tests**:
- Test with random parameter types
- Verify serialization round-trips
- Check error handling paths

## Conclusion

The bidirectional tool bridge implementation successfully demonstrates the core concept of transparent cross-language tool execution. The architecture is sound and the basic functionality works as designed. However, several challenges remain before the system is production-ready:

1. **Type System**: Need better type validation and complex type support
2. **Performance**: Current implementation has ~10ms overhead per call
3. **Reliability**: Missing session cleanup and error recovery
4. **Security**: No access control or parameter validation
5. **Observability**: Limited monitoring and debugging capabilities

The implementation provides a solid foundation for the vision of "orchestration over reimplementation," allowing each language to handle what it does best. With the recommended improvements, this system could become a powerful tool for building hybrid Elixir-Python applications.

## Appendix: Known Issues and Workarounds

### Issue 1: Session Already Exists Error
**Symptom**: `Session already exists: bidirectional-demo`
**Workaround**: Clean up session before creating:
```elixir
SessionStore.delete_session(session_id)
{:ok, _} = SessionStore.create_session(session_id, metadata)
```

### Issue 2: Metadata Encoding Error
**Symptom**: `:description is invalid for type :string`
**Workaround**: Convert all atoms to strings before sending to protobuf

### Issue 3: Port Already in Use
**Symptom**: `:eaddrinuse (address already in use)`
**Workaround**: Kill existing processes or use different port

### Issue 4: Import Path Issues
**Symptom**: `duplicate file name snakepit_bridge.proto`
**Workaround**: Ensure single source of protobuf files, remove duplicates