# Bidirectional Tool Bridge - Technical Documentation

## Overview

The Bidirectional Tool Bridge enables seamless cross-language function execution between Elixir and Python in the Snakepit framework. This allows developers to leverage the strengths of both languages within a single application, calling Python functions from Elixir and Elixir functions from Python transparently through gRPC.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        Elixir Side                              │
├─────────────────────────────────────────────────────────────────┤
│  ToolRegistry (GenServer)                                       │
│    - ETS table: :snakepit_tool_registry                        │
│    - Manages tool metadata and execution                        │
│                                                                 │
│  BridgeServer (gRPC handlers)                                   │
│    - register_tools/2                                           │
│    - get_exposed_elixir_tools/2                                 │
│    - execute_elixir_tool/2                                      │
│    - execute_tool/2                                             │
└─────────────────────────────────────────────────────────────────┘
                            ↕ gRPC
┌─────────────────────────────────────────────────────────────────┐
│                        Python Side                              │
├─────────────────────────────────────────────────────────────────┤
│  SessionContext                                                 │
│    - Auto-discovers Elixir tools on init                       │
│    - Creates dynamic proxies for natural Python syntax          │
│    - Manages tool execution and serialization                   │
│                                                                 │
│  BaseAdapter                                                    │
│    - @tool decorator for exposing Python functions              │
│    - Automatic tool discovery and registration                  │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Expose Elixir Functions to Python

```elixir
# In your Elixir code
alias Snakepit.Bridge.ToolRegistry

# Register a function to be callable from Python
ToolRegistry.register_elixir_tool(
  session_id, 
  "parse_json",
  &MyModule.parse_json/1,
  %{
    description: "Parse a JSON string",
    exposed_to_python: true,  # Important!
    parameters: [
      %{name: "json_string", type: "string", required: true}
    ]
  }
)
```

### 2. Call Elixir Functions from Python

```python
from snakepit_bridge.session_context import SessionContext

# Connect to session
ctx = SessionContext(stub, session_id)

# Method 1: Direct call
result = ctx.call_elixir_tool("parse_json", json_string='{"test": true}')

# Method 2: Using tool proxy (more Pythonic)
result = ctx.elixir_tools["parse_json"](json_string='{"test": true}')
```

### 3. Expose Python Functions to Elixir

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    @tool(description="Process data with Python")
    def process_data(self, data: str, mode: str = "default") -> dict:
        # Your Python logic here
        return {"processed": data, "mode": mode}

# Register with session (happens automatically in grpc_server.py)
adapter = MyAdapter()
adapter.register_with_session(session_id, stub)
```

### 4. Call Python Functions from Elixir

```elixir
# Execute a Python tool (once registered)
{:ok, result} = ToolRegistry.execute_tool(session_id, "process_data", %{
  "data" => "test input",
  "mode" => "advanced"
})
```

## Detailed Implementation Guide

### Setting Up Elixir Tools

1. **Define Your Function**
   ```elixir
   defmodule MyTools do
     def calculate_stats(params) do
       list = Map.get(params, "numbers", [])
       %{
         sum: Enum.sum(list),
         mean: Enum.sum(list) / length(list),
         max: Enum.max(list)
       }
     end
   end
   ```

2. **Register During Application Startup**
   ```elixir
   # In your application.ex or supervisor
   ToolRegistry.register_elixir_tool(
     session_id,
     "calculate_stats",
     &MyTools.calculate_stats/1,
     %{
       description: "Calculate statistics for a list of numbers",
       exposed_to_python: true,
       parameters: [
         %{name: "numbers", type: "array", required: true}
       ]
     }
   )
   ```

### Setting Up Python Tools

1. **Create an Adapter Class**
   ```python
   from snakepit_bridge.base_adapter import BaseAdapter, tool
   import numpy as np
   
   class DataAdapter(BaseAdapter):
       @tool(description="Perform FFT on signal data")
       def fft_analysis(self, signal: list, sample_rate: int = 1000) -> dict:
           fft_result = np.fft.fft(signal)
           frequencies = np.fft.fftfreq(len(signal), 1/sample_rate)
           
           return {
               "dominant_frequency": float(frequencies[np.argmax(np.abs(fft_result))]),
               "magnitude": float(np.max(np.abs(fft_result))),
               "sample_rate": sample_rate
           }
   ```

2. **Integration with gRPC Server**
   ```python
   # In your grpc_server.py
   adapter = DataAdapter()
   
   # This happens automatically when adapter is used in ExecuteTool
   tool_names = adapter.register_with_session(session_id, stub)
   ```

### Parameter Types and Serialization

The bridge supports these parameter types:

| Type | Elixir | Python | Notes |
|------|--------|---------|-------|
| string | String.t() | str | Direct mapping |
| integer | integer() | int | Direct mapping |
| float | float() | float | Direct mapping |
| boolean | boolean() | bool | Direct mapping |
| array | list() | list | JSON serialization |
| object | map() | dict | JSON serialization |
| null | nil | None | Direct mapping |

**Complex Type Example:**
```python
# Python sending complex data to Elixir
result = ctx.call_elixir_tool("process_data", 
    matrix=[[1, 2], [3, 4]],
    config={"threshold": 0.5, "mode": "fast"}
)
```

### Error Handling

```python
# Python side
try:
    result = ctx.call_elixir_tool("risky_operation", data=input_data)
except RuntimeError as e:
    print(f"Elixir tool failed: {e}")
    # Handle error appropriately
```

```elixir
# Elixir side
def risky_operation(params) do
  case validate_input(params) do
    :ok -> 
      {:ok, perform_operation(params)}
    {:error, reason} ->
      {:error, "Validation failed: #{reason}"}
  end
end
```

## Advanced Features

### 1. Session-Scoped Tools

Tools are isolated by session, allowing multi-tenant usage:

```python
# Different sessions have different tools
ctx1 = SessionContext(stub, "session-1")
ctx2 = SessionContext(stub, "session-2")

# Each context only sees tools registered for its session
print(ctx1.elixir_tools.keys())  # Tools for session-1
print(ctx2.elixir_tools.keys())  # Tools for session-2
```

### 2. Dynamic Tool Discovery

Tools are discovered automatically:

```python
# Python discovers Elixir tools on initialization
ctx = SessionContext(stub, session_id)
# ctx.elixir_tools is automatically populated

# List all available Elixir tools
for name, proxy in ctx.elixir_tools.items():
    print(f"{name}: {proxy.__doc__}")
```

### 3. Metadata and Introspection

```python
# Access tool metadata
tool_proxy = ctx.elixir_tools["calculate_stats"]
print(tool_proxy.__name__)  # "calculate_stats"
print(tool_proxy.__doc__)   # Full description with parameters
```

### 4. Hybrid Processing Patterns

```python
# Combine Python and Elixir strengths
class HybridAdapter(BaseAdapter):
    def __init__(self, session_context):
        self.ctx = session_context
    
    @tool(description="Hybrid ML pipeline")
    def ml_pipeline(self, raw_data: list) -> dict:
        # Python: Data preprocessing with pandas/numpy
        processed = self.preprocess(raw_data)
        
        # Elixir: Parallel processing
        distributed_result = self.ctx.call_elixir_tool(
            "parallel_map", 
            data=processed,
            function="complex_calculation"
        )
        
        # Python: ML model inference
        predictions = self.model.predict(distributed_result["results"])
        
        return {
            "predictions": predictions.tolist(),
            "processing_time": distributed_result["elapsed_ms"]
        }
```

## Performance Considerations

### Benchmarks

Typical overhead for cross-language calls:
- Simple parameter types: ~1-2ms
- Complex objects (1KB JSON): ~5-10ms
- Large arrays (10MB): ~50-100ms

### Optimization Tips

1. **Batch Operations**
   ```python
   # Instead of multiple calls
   results = []
   for item in items:
       results.append(ctx.call_elixir_tool("process", data=item))
   
   # Use a single batched call
   results = ctx.call_elixir_tool("process_batch", items=items)
   ```

2. **Cache Frequently Used Tools**
   ```python
   # Store proxy reference
   process_fn = ctx.elixir_tools["process_data"]
   
   # Reuse in hot loops
   for data in large_dataset:
       result = process_fn(data=data)
   ```

3. **Minimize Serialization**
   ```elixir
   # Return only necessary data
   def analyze_large_dataset(params) do
     dataset = decode_dataset(params["data"])
     
     # Don't return the entire dataset
     %{
       summary: calculate_summary(dataset),
       metrics: extract_metrics(dataset),
       # Not: processed_data: dataset
     }
   end
   ```

## Troubleshooting

### Common Issues

1. **"Tool not found" Error**
   - Ensure `exposed_to_python: true` is set in Elixir tool metadata
   - Verify the session ID matches between Python and Elixir
   - Check that the Elixir tool was registered before Python tried to discover it

2. **Serialization Errors**
   - Ensure all return values are JSON-serializable
   - Use basic types (string, number, boolean, array, object)
   - For binary data, base64 encode it first

3. **Connection Refused**
   - Verify gRPC server is running: `lsof -i :50051`
   - Check firewall settings
   - Ensure correct host/port in Python client

4. **Session Already Exists**
   ```elixir
   # Clean up before creating
   SessionStore.delete_session(session_id)
   {:ok, _} = SessionStore.create_session(session_id, metadata: %{})
   ```

### Debug Mode

Enable detailed logging:

```python
# Python
import logging
logging.getLogger('snakepit_bridge').setLevel(logging.DEBUG)
```

```elixir
# Elixir - in config.exs
config :logger, level: :debug
```

## Security Considerations

1. **Input Validation**: Always validate parameters in tool implementations
2. **Access Control**: Implement session-based permissions if needed
3. **Rate Limiting**: Consider implementing rate limits for expensive operations
4. **Sanitization**: Sanitize error messages to avoid leaking sensitive information

## Future Enhancements

### Currently In Development

1. **Streaming Support**: For long-running operations
   ```python
   # Future API
   for progress in ctx.stream_elixir_tool("long_operation", data=data):
       print(f"Progress: {progress.percent}%")
   ```

2. **Binary Data Optimization**: Direct binary transfer without JSON encoding
3. **Connection Pooling**: Reuse gRPC connections for better performance
4. **Automatic Retries**: With exponential backoff for transient failures

## Examples

Complete working examples are available in the `examples/` directory:

- `bidirectional_tools_demo.exs` - Elixir server with example tools
- `python_elixir_tools_demo.py` - Python client demonstrating all features
- `elixir_python_tools_demo.exs` - Elixir calling Python tools (coming soon)

## Contributing

When adding new features to the tool bridge:

1. Update the protobuf definitions if needed
2. Implement both Elixir and Python sides
3. Add tests for serialization edge cases
4. Update this documentation
5. Add examples demonstrating the feature

## Related Documentation

- [Implementation Plan](docs/bidirectional_tool_bridge_implementation_plan.md)
- [As-Built Documentation](docs/bidirectional_tool_bridge_as_built.md)
- [Main README](README.md)