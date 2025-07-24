# Bidirectional Tool Bridge Implementation Plan

## Executive Summary

This document outlines a comprehensive implementation plan for creating a bidirectional tool bridge between Elixir and Python in the Snakepit framework. The goal is to enable seamless cross-language tool execution where Python DSPy programs can transparently call Elixir functions and vice versa, creating a unified tool ecosystem.

### Current State
- **60% Complete**: Core gRPC infrastructure, session management, and variable operations are fully implemented
- **40% Missing**: Tool discovery, registration, bidirectional execution, and transparent proxying

### Target State
- Full bidirectional tool execution via gRPC
- Transparent tool proxying ("multing") for unmodified DSPy programs
- Dynamic tool discovery and registration
- Streaming support for long-running operations

## Architecture Overview

### Core Components

```
┌─────────────────────┐         ┌─────────────────────┐
│   Elixir Side       │         │   Python Side       │
├─────────────────────┤         ├─────────────────────┤
│  ToolRegistry       │◄────────┤  SessionContext     │
│  (GenServer)        │         │  - call_elixir_tool │
├─────────────────────┤         ├─────────────────────┤
│  BridgeServer       │         │  ToolProxy          │
│  - execute_tool     │────────►│  (Dynamic)          │
│  - execute_elixir   │◄────────┤                     │
├─────────────────────┤         ├─────────────────────┤
│  SessionStore       │         │  Adapters           │
│  (State)            │         │  - get_tools()      │
└─────────────────────┘         └─────────────────────┘
           ▲                               ▲
           │        gRPC Bridge            │
           └───────────────────────────────┘
```

### Data Flow

1. **Tool Registration** (Startup)
   - Python adapter calls `RegisterTools` RPC
   - Elixir ToolRegistry stores tool metadata
   - Session initialization includes tool manifest

2. **Python → Elixir** (Runtime)
   - DSPy program calls tool (via ToolProxy)
   - SessionContext makes `ExecuteElixirTool` RPC
   - BridgeServer executes Elixir function
   - Result serialized and returned

3. **Elixir → Python** (Runtime)
   - Elixir code calls `DSPex.Tools.execute/3`
   - BridgeServer makes `ExecuteTool` RPC
   - Python server executes adapter method
   - Result returned to Elixir

## Implementation Phases

### Phase 1: Tool Registry and Discovery (Week 1-2)

#### 1.1 Elixir ToolRegistry GenServer
**File**: `lib/snakepit/bridge/tool_registry.ex`

```elixir
defmodule Snakepit.Bridge.ToolRegistry do
  use GenServer
  
  # State structure
  # %{
  #   session_id => %{
  #     tool_name => %ToolSpec{
  #       name: String.t(),
  #       type: :local | :remote,
  #       handler: function() | worker_id,
  #       parameters: [...],
  #       metadata: %{}
  #     }
  #   }
  # }
  
  def register_tool(session_id, tool_name, spec)
  def get_tool(session_id, tool_name)
  def list_tools(session_id)
  def execute_local_tool(session_id, tool_name, params)
end
```

**Tasks**:
- [ ] Create GenServer with ETS backing for performance
- [ ] Implement tool registration with validation
- [ ] Add tool lookup and listing functionality
- [ ] Create ToolSpec struct with metadata support

#### 1.2 Python Tool Discovery
**File**: `priv/python/snakepit_bridge/base_adapter.py`

```python
class BaseAdapter:
    def get_tools(self) -> List[ToolSpec]:
        """Discover and return tool specifications"""
        tools = []
        for name, method in inspect.getmembers(self, inspect.ismethod):
            if hasattr(method, '_tool_metadata'):
                spec = self._create_tool_spec(name, method)
                tools.append(spec)
        return tools
    
    def _create_tool_spec(self, name: str, method: Callable) -> ToolSpec:
        """Generate ToolSpec from method signature"""
        sig = inspect.signature(method)
        return ToolSpec(
            name=name,
            parameters=self._extract_parameters(sig),
            description=method.__doc__,
            metadata={'streaming': getattr(method, '_streaming', False)}
        )
```

**Tasks**:
- [ ] Implement base adapter with tool discovery
- [ ] Create tool decorator for metadata annotation
- [ ] Generate ToolSpec from function signatures
- [ ] Update ShowcaseAdapter to use new pattern

#### 1.3 Tool Registration RPC
**Proto Addition**: `priv/proto/snakepit_bridge.proto`

```protobuf
rpc RegisterTools(RegisterToolsRequest) returns (RegisterToolsResponse) {}

message RegisterToolsRequest {
  string session_id = 1;
  repeated ToolSpec tools = 2;
}

message RegisterToolsResponse {
  bool success = 1;
  map<string, string> tool_ids = 2;
}
```

**Tasks**:
- [ ] Add RegisterTools RPC to proto
- [ ] Implement handler in BridgeServer
- [ ] Update Python server to call on startup
- [ ] Add tool validation logic

### Phase 2: Tool Execution Implementation (Week 3-4)

#### 2.1 Execute Tool in BridgeServer
**File**: `lib/snakepit/grpc/bridge_server.ex`

```elixir
def execute_tool(request, _stream) do
  with {:ok, session} <- SessionStore.get_session(request.session_id),
       {:ok, tool} <- ToolRegistry.get_tool(request.session_id, request.tool_name),
       {:ok, params} <- deserialize_parameters(request.parameters),
       {:ok, result} <- execute_tool_handler(tool, params, session) do
    
    response = %ExecuteToolResponse{
      result: serialize_result(result),
      metadata: %{
        "execution_time" => execution_time,
        "tool_version" => tool.metadata["version"]
      }
    }
    {:ok, response}
  else
    {:error, reason} -> 
      {:error, GRPC.Status.new(code: :not_found, message: reason)}
  end
end

defp execute_tool_handler(%{type: :local} = tool, params, session) do
  ToolRegistry.execute_local_tool(session.id, tool.name, params)
end

defp execute_tool_handler(%{type: :remote} = tool, params, session) do
  # Forward to Python worker
  Python.Worker.execute_tool(tool.worker_id, tool.name, params)
end
```

**Tasks**:
- [ ] Implement execute_tool handler
- [ ] Add parameter deserialization
- [ ] Create execution dispatch logic
- [ ] Add error handling and telemetry

#### 2.2 Python to Elixir Tool Calls
**File**: `priv/python/snakepit_bridge/session_context.py`

```python
class SessionContext:
    def __init__(self, session_id: str, elixir_stub):
        self.session_id = session_id
        self.stub = elixir_stub
        self._elixir_tools = {}
        self._load_elixir_tools()
    
    def _load_elixir_tools(self):
        """Load available Elixir tools on initialization"""
        request = GetExposedToolsRequest(session_id=self.session_id)
        response = self.stub.GetExposedTools(request)
        
        for tool_spec in response.tools:
            proxy = self._create_tool_proxy(tool_spec)
            self._elixir_tools[tool_spec.name] = proxy
    
    def _create_tool_proxy(self, tool_spec: ToolSpec):
        """Create a Python callable that proxies to Elixir"""
        def proxy(**kwargs):
            return self.call_elixir_tool(tool_spec.name, **kwargs)
        
        proxy.__name__ = tool_spec.name
        proxy.__doc__ = tool_spec.description
        proxy.__annotations__ = self._build_annotations(tool_spec)
        return proxy
    
    async def call_elixir_tool(self, tool_name: str, **kwargs):
        """Execute an Elixir tool via gRPC"""
        request = ExecuteElixirToolRequest(
            session_id=self.session_id,
            tool_name=tool_name,
            parameters={k: self._serialize_value(v) for k, v in kwargs.items()}
        )
        
        response = await self.stub.ExecuteElixirTool(request)
        return self._deserialize_result(response.result)
```

**Tasks**:
- [ ] Add ExecuteElixirTool RPC to proto
- [ ] Implement tool proxy generation
- [ ] Create serialization helpers
- [ ] Add async/await support

### Phase 3: Transparent Tool Integration (Week 5-6)

#### 3.1 DSPy Integration
**File**: `priv/python/snakepit_bridge/dspy_integration.py`

```python
class DSPyToolProvider:
    """Provides tools to DSPy programs transparently"""
    
    def __init__(self, session_context: SessionContext):
        self.context = session_context
        self._all_tools = self._merge_tools()
    
    def _merge_tools(self):
        """Merge Python and Elixir tools into unified set"""
        tools = {}
        
        # Add Python tools from adapter
        for name, func in self.context.adapter.get_tools().items():
            tools[name] = func
        
        # Add Elixir tool proxies
        for name, proxy in self.context._elixir_tools.items():
            tools[name] = proxy
        
        return tools
    
    def get_tools_for_dspy(self) -> List[Callable]:
        """Return tool list compatible with DSPy ReAct"""
        return list(self._all_tools.values())
```

**Example Usage**:
```python
# Transparent usage in DSPy
provider = DSPyToolProvider(session_context)
tools = provider.get_tools_for_dspy()

# DSPy ReAct agent uses tools without knowing they're from Elixir
agent = dspy.ReAct("question -> answer", tools=tools)
result = agent(question="Process this data using Elixir's parser")
```

**Tasks**:
- [ ] Create DSPyToolProvider class
- [ ] Implement tool merging logic
- [ ] Add metadata preservation
- [ ] Test with ReAct agents

#### 3.2 Streaming Tool Support
**File**: `lib/snakepit/grpc/streaming_tool_executor.ex`

```elixir
defmodule Snakepit.Bridge.StreamingToolExecutor do
  def execute_streaming(tool, params, session_id) do
    Stream.resource(
      fn -> init_tool_execution(tool, params) end,
      fn state -> 
        case get_next_chunk(state) do
          {:ok, chunk, new_state} -> 
            {[chunk], new_state}
          :done -> 
            {:halt, state}
        end
      end,
      fn state -> cleanup_tool_execution(state) end
    )
  end
end
```

**Tasks**:
- [ ] Implement streaming execution
- [ ] Add chunk serialization
- [ ] Create backpressure handling
- [ ] Support mid-stream tool calls

### Phase 4: Production Hardening (Week 7-8)

#### 4.1 Observability and Telemetry
```elixir
defmodule Snakepit.Bridge.Telemetry do
  def setup do
    attach_many("tool-bridge", [
      [:snakepit, :tool, :execute, :start],
      [:snakepit, :tool, :execute, :stop],
      [:snakepit, :tool, :register],
      [:snakepit, :tool, :discovery]
    ], &handle_event/4, nil)
  end
  
  defp handle_event([:snakepit, :tool, :execute, :stop], measurements, metadata, _) do
    Logger.info("Tool executed", 
      tool: metadata.tool_name,
      duration: measurements.duration,
      session: metadata.session_id
    )
  end
end
```

**Tasks**:
- [ ] Add telemetry events
- [ ] Create metrics collection
- [ ] Implement distributed tracing
- [ ] Add performance monitoring

#### 4.2 Security and Validation
```python
class ToolSecurityValidator:
    def __init__(self, allowed_tools: Set[str], capabilities: Dict[str, List[str]]):
        self.allowed_tools = allowed_tools
        self.capabilities = capabilities
    
    def validate_tool_call(self, session_id: str, tool_name: str, params: Dict):
        if tool_name not in self.allowed_tools:
            raise SecurityError(f"Tool {tool_name} not allowed for session")
        
        required_capabilities = self.capabilities.get(tool_name, [])
        if not self._has_capabilities(session_id, required_capabilities):
            raise SecurityError(f"Insufficient capabilities for {tool_name}")
```

**Tasks**:
- [ ] Implement capability-based security
- [ ] Add parameter validation
- [ ] Create rate limiting
- [ ] Add audit logging

## Testing Strategy

### Unit Tests
- ToolRegistry CRUD operations
- Tool discovery mechanisms
- Serialization/deserialization
- Security validation

### Integration Tests
- Bidirectional tool calls
- DSPy ReAct agent compatibility
- Streaming tool execution
- Error propagation

### Performance Tests
- Tool call latency (target: <10ms)
- Streaming throughput
- Concurrent session handling
- Memory usage under load

## Success Criteria

### Functional Requirements
- [x] Python can discover and call Elixir tools
- [x] Elixir can execute Python adapter methods
- [x] DSPy programs work unmodified with Elixir tools
- [x] Streaming tools support backpressure
- [x] Tool metadata and introspection available

### Performance Requirements
- Tool call overhead: <10ms
- First stream chunk: <50ms
- Tool discovery: <100ms per session
- Memory overhead: <1MB per session

### Developer Experience
- Type hints and auto-completion in Python
- Rich error messages with context
- Comprehensive documentation
- Example implementations

## Migration Path

### Stage 1: Alpha Release (Week 6)
- Basic bidirectional execution
- Manual tool registration
- Limited to non-streaming tools

### Stage 2: Beta Release (Week 8)
- Full tool discovery
- Streaming support
- DSPy integration tested

### Stage 3: Production Release (Week 10)
- Security hardening complete
- Performance optimized
- Full observability

## Risk Mitigation

### Technical Risks
1. **Serialization Performance**
   - Mitigation: Use binary formats for large data
   - Fallback: Implement chunking for oversized payloads

2. **Circular Dependencies**
   - Mitigation: Implement call stack tracking
   - Fallback: Set maximum recursion depth

3. **Network Latency**
   - Mitigation: Connection pooling and keep-alive
   - Fallback: Local caching of frequently used tools

### Operational Risks
1. **Backward Compatibility**
   - Mitigation: Version negotiation in handshake
   - Fallback: Maintain legacy endpoints

2. **Resource Exhaustion**
   - Mitigation: Rate limiting and quotas
   - Fallback: Circuit breakers

## Conclusion

This implementation plan provides a clear path to achieving full bidirectional tool execution between Elixir and Python. By building on the existing gRPC infrastructure and following a phased approach, we can deliver incremental value while working toward the complete vision of transparent cross-language tool integration.

The key innovation is the "multing" concept - making remote tools appear local through dynamic proxy generation. This enables DSPy programs to leverage Elixir's strengths (concurrency, fault tolerance, state management) without modification, truly achieving the goal of "orchestration over reimplementation."

## Appendix: Code Examples

### Example 1: Registering an Elixir Tool
```elixir
# In your Elixir application
defmodule DataProcessor do
  def parse_logs(text, format \\ :json) do
    # Elixir parsing logic
    {:ok, parsed_data}
  end
end

# Register the tool
ToolRegistry.register_elixir_tool(
  :parse_logs,
  &DataProcessor.parse_logs/2,
  %{
    description: "Parse log files in various formats",
    parameters: [
      %{name: "text", type: :string, required: true},
      %{name: "format", type: :atom, required: false, default: :json}
    ]
  }
)
```

### Example 2: Using Elixir Tools from Python
```python
# In a DSPy program
import dspy

# Session context automatically loads available tools
ctx = SessionContext(session_id="my-session")

# Get the Elixir tool as a Python function
parse_logs = ctx.elixir_tools["parse_logs"]

# Use it directly
result = parse_logs(text=log_content, format="json")

# Or use it with DSPy ReAct
agent = dspy.ReAct("logs -> insights", tools=[parse_logs])
insights = agent(logs=log_content)
```

### Example 3: Bidirectional Tool Composition
```python
# Python tool that uses Elixir tools internally
@tool(streaming=True)
async def analyze_system_health(ctx: SessionContext):
    # Call Elixir tool to get system metrics
    metrics = await ctx.call_elixir_tool("get_system_metrics")
    
    # Process in Python
    analysis = ml_model.analyze(metrics)
    
    # Store results using Elixir tool
    await ctx.call_elixir_tool("store_analysis", 
                               analysis=analysis,
                               timestamp=datetime.now())
    
    yield {"status": "complete", "summary": analysis.summary}
```