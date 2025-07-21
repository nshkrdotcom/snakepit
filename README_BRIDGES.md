# Snakepit Python Bridges Documentation

## Overview

Snakepit provides multiple Python bridge implementations to enable communication between Elixir and Python processes. Each bridge version offers different capabilities and trade-offs, allowing you to choose the best fit for your use case.

## Bridge Versions

### 1. V1 Generic Bridge (Deprecated)
**File**: `priv/python/generic_bridge.py`  
**Status**: Deprecated - Use V2 for new projects

The original bridge implementation that established the core protocol:
- Simple stdin/stdout communication
- 4-byte length header + JSON payload protocol
- Basic command handler pattern
- Built-in error handling and graceful shutdown

**Features**:
- Minimal dependencies (only Python stdlib)
- Extensible via `BaseCommandHandler` class
- Built-in commands: ping, echo, compute, info
- Signal handling for clean shutdown

**Example Usage**:
```python
class MyCustomHandler(BaseCommandHandler):
    def _register_commands(self):
        self.register_command("my_command", self.handle_my_command)
    
    def handle_my_command(self, args):
        return {"result": "processed", "input": args}

handler = ProtocolHandler(MyCustomHandler())
handler.run()
```

### 2. V2 Generic Bridge (Current)
**File**: `priv/python/generic_bridge_v2.py`  
**Status**: Active - Recommended for production

A complete rewrite with proper package structure and enhanced features:
- Uses the `snakepit_bridge` package for modularity
- Support for multiple wire protocols (JSON, MessagePack, auto-detection)
- Better error handling and broken pipe suppression
- Production-ready architecture

**Key Improvements**:
- Modular package structure (`snakepit_bridge/*`)
- Protocol abstraction (JSON/MessagePack)
- Cleaner separation of concerns
- Better testing support
- Command-line options for configuration

**Usage**:
```bash
python generic_bridge_v2.py --mode pool-worker --protocol msgpack --quiet
```

**Package Structure**:
```
snakepit_bridge/
├── __init__.py       # Package exports
├── core.py           # Core protocol handling
├── adapters/         # Command handler implementations
│   ├── generic.py    # Default generic handler
│   └── grpc_streaming.py  # gRPC streaming adapter
└── cli/              # CLI entry points
```

### 3. Enhanced Bridge (DSPy/ML Focused)
**File**: `priv/python/enhanced_bridge.py`  
**Status**: Active - Used by DSPex

Built on V2 architecture with dynamic method invocation capabilities:
- Universal Python method calls via dynamic invocation
- Object persistence and lifecycle management
- Framework plugin system for optimized integrations
- Smart serialization with type awareness
- Backward compatibility with V2 commands

**Key Features**:
- **Dynamic Method Invocation**: Call any Python method/class dynamically
- **Object Storage**: Store and retrieve Python objects between calls
- **Framework Plugins**: Optimized support for DSPy, Transformers, Pandas
- **Pipeline Support**: Execute sequences of operations
- **Inspection**: Introspect objects and their capabilities

**Command Set**:
```elixir
# Dynamic calls
{:ok, result} = Python.call(pid, "dspy.Predict", %{signature: "question -> answer"})
{:ok, result} = Python.call(pid, "stored.my_obj.forward", %{input: "test"})

# Storage management
{:ok, _} = Python.store(pid, "my_model", model)
{:ok, model} = Python.retrieve(pid, "my_model")

# Pipeline execution
{:ok, results} = Python.pipeline(pid, [
  %{target: "dspy.configure", kwargs: %{lm: "gemini"}},
  %{target: "dspy.Predict", kwargs: %{signature: sig}, store_as: "predictor"},
  %{target: "stored.predictor.forward", kwargs: inputs}
])
```

**Framework Plugins**:
1. **DSPyPlugin**: 
   - Special handling for Prediction objects
   - Gemini configuration support
   - Automatic attribute extraction

2. **TransformersPlugin**:
   - Pipeline serialization
   - Model information extraction

3. **PandasPlugin**:
   - DataFrame/Series serialization
   - Shape and dtype information

### 4. gRPC Bridge (Streaming/High-Performance)
**File**: `priv/python/grpc_bridge.py`  
**Status**: Experimental - For streaming use cases

Modern gRPC-based bridge for advanced features:
- True bidirectional streaming
- Multiplexing support
- Session management
- Binary data handling
- Health checks and monitoring

**Features**:
- Replaces stdin/stdout with gRPC protocol
- Supports streaming responses
- Better performance for high-throughput scenarios
- Session-based execution
- Worker statistics and monitoring

**Protocol**:
```protobuf
service SnakepitBridge {
  rpc Execute(ExecuteRequest) returns (ExecuteResponse);
  rpc ExecuteStream(ExecuteRequest) returns (stream StreamResponse);
  rpc ExecuteInSession(SessionRequest) returns (ExecuteResponse);
  rpc ExecuteInSessionStream(SessionRequest) returns (stream StreamResponse);
  rpc Health(HealthRequest) returns (HealthResponse);
  rpc GetInfo(InfoRequest) returns (InfoResponse);
}
```

**Usage**:
```bash
# Start gRPC server
python grpc_bridge.py --port 50051

# With custom adapter
python grpc_bridge.py --port 50051 --adapter my_module.MyAdapter
```

## Bridge Selection Guide

### Use V2 Generic Bridge when:
- You need a stable, production-ready solution
- Your use case involves simple request/response patterns
- You want minimal dependencies
- You're building custom adapters

### Use Enhanced Bridge when:
- Working with ML frameworks (DSPy, Transformers, etc.)
- You need dynamic method invocation
- Object persistence between calls is required
- Building complex ML pipelines
- Integrating with DSPex

### Use gRPC Bridge when:
- Streaming responses are required
- High-throughput communication is needed
- Session management is important
- You need better monitoring/observability

### Avoid V1 Bridge:
- Deprecated and will be removed
- V2 provides all features with better architecture

## Creating Custom Adapters

All bridges support custom adapters by extending `BaseCommandHandler`:

```python
from snakepit_bridge import BaseCommandHandler, ProtocolHandler

class MyMLHandler(BaseCommandHandler):
    def _register_commands(self):
        self.register_command("train", self.handle_train)
        self.register_command("predict", self.handle_predict)
    
    def handle_train(self, args):
        # Training logic here
        return {"status": "trained", "metrics": {...}}
    
    def handle_predict(self, args):
        # Prediction logic here
        return {"predictions": [...]}

# Use with any bridge version
handler = ProtocolHandler(MyMLHandler())
handler.run()
```

## Wire Protocol

All bridges (except gRPC) use the same wire protocol:

1. **Length Header**: 4 bytes, big-endian, indicating payload size
2. **Payload**: JSON or MessagePack encoded data

**Request Format**:
```json
{
  "id": "unique-request-id",
  "command": "command_name",
  "args": {
    "param1": "value1",
    "param2": "value2"
  }
}
```

**Response Format**:
```json
{
  "id": "unique-request-id",
  "success": true,
  "result": {
    "data": "response data"
  },
  "timestamp": "2024-01-01T00:00:00Z"
}
```

## Performance Considerations

1. **JSON vs MessagePack**: MessagePack is ~2-3x faster for large payloads
2. **Object Storage**: Enhanced bridge keeps objects in memory, avoiding serialization overhead
3. **gRPC Streaming**: Best for real-time data or large responses
4. **Pool Size**: Configure based on workload (default: 4 workers)

## Error Handling

All bridges implement robust error handling:
- Graceful shutdown on SIGTERM/SIGINT
- Broken pipe detection and suppression
- Timeout support (configured in Snakepit)
- Detailed error messages with stack traces

## Migration Guide

### From V1 to V2:
1. Update import: Use `snakepit_bridge` package
2. Change startup: Use `generic_bridge_v2.py`
3. Commands remain compatible

### From Generic to Enhanced:
1. Replace bridge script with `enhanced_bridge.py`
2. Existing commands work unchanged
3. New dynamic features available immediately

### To gRPC:
1. Install gRPC dependencies: `pip install grpcio`
2. Generate protobuf files: `make proto-python`
3. Update Snakepit configuration for gRPC mode
4. Implement streaming in your adapter if needed

## Best Practices

1. **Choose the Right Bridge**: Match bridge capabilities to your needs
2. **Handle Errors Gracefully**: Always wrap calls in try/except
3. **Manage Object Lifecycle**: Clean up stored objects when done
4. **Monitor Performance**: Use built-in metrics (uptime, request count)
5. **Test Thoroughly**: Each bridge has different edge cases
6. **Version Dependencies**: Pin Python package versions for stability

## Troubleshooting

### Common Issues:

1. **ImportError**: Bridge package not in Python path
   - Solution: Ensure `snakepit_bridge` directory is accessible

2. **Broken Pipe Errors**: Elixir process terminated
   - Solution: Bridges handle this automatically, check Elixir logs

3. **Serialization Errors**: Complex objects can't be JSON encoded
   - Solution: Use Enhanced bridge with smart serialization

4. **Performance Issues**: Slow response times
   - Solution: Switch to MessagePack or gRPC, increase pool size

5. **Memory Growth**: Stored objects not cleaned up
   - Solution: Call `clear_session` or `delete_stored` periodically

## Future Roadmap

1. **Arrow Support**: Apache Arrow for zero-copy data transfer
2. **Async Support**: asyncio integration for better concurrency
3. **Distributed Mode**: Multi-node Python worker support
4. **GPU Support**: CUDA-aware serialization
5. **Monitoring**: OpenTelemetry integration