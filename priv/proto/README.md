# Snakepit Bridge Protocol Documentation

## Overview

The `snakepit_bridge.proto` file defines the unified gRPC protocol for the DSPex bridge, supporting both tool execution and variable management with streaming capabilities.

## Protocol Version

- **Version**: 1.0.0
- **Package**: `snakepit.bridge`

## Service Definition

The `SnakepitBridge` service provides the following RPC methods:

### Health & Session Management

- `Ping` - Health check endpoint
- `InitializeSession` - Initialize a new session with configuration
- `CleanupSession` - Clean up session resources

### Variable Operations

- `GetVariable` - Get a single variable value
- `SetVariable` - Update a variable value
- `GetVariables` - Batch get multiple variables
- `SetVariables` - Batch set multiple variables
- `RegisterVariable` - Register a new variable in the session

### Tool Execution

- `ExecuteTool` - Execute a tool synchronously
- `ExecuteStreamingTool` - Execute a tool with streaming results

### Streaming & Reactive

- `WatchVariables` - Stream variable updates in real-time

### Advanced Features (Stage 4)

- `AddDependency` - Add dependency between variables
- `StartOptimization` - Start variable optimization
- `StopOptimization` - Stop ongoing optimization
- `GetVariableHistory` - Get variable change history
- `RollbackVariable` - Rollback variable to previous version

## Binary Serialization

The protocol includes automatic binary serialization for efficient handling of large data:

### Overview
- **Automatic**: Triggered when data exceeds 10KB threshold
- **Transparent**: No API changes required
- **Optimized**: 5-10x faster for large tensors and embeddings
- **Types**: Currently supports `tensor` and `embedding` types

### Binary Fields
- `Variable.binary_value` (field 12): Stores large variable data
- `SetVariableRequest.binary_value` (field 6): Binary data for updates
- `RegisterVariableRequest.initial_binary_value` (field 7): Initial binary value
- `BatchSetVariablesRequest.binary_updates` (field 5): Map of binary updates
- `ExecuteToolRequest.binary_parameters` (field 6): Binary tool parameters

### Format
- **Metadata**: Stored in the standard `value` field as JSON
  - Contains: shape, dtype, binary_format, type
- **Binary Data**: Stored in the `binary_value` field
  - Elixir side: Erlang Term Format (ETF)
  - Python side: Python pickle format

### Example
```protobuf
// For a large tensor
Variable {
  name: "large_tensor"
  type: "tensor"
  value: Any {
    type_url: "type.googleapis.com/snakepit.tensor.binary"
    value: "{\"shape\": [1000, 1000], \"dtype\": \"float32\", \"binary_format\": \"pickle\"}"
  }
  binary_value: <8MB of binary data>
}
```

## Type System

The protocol supports the following variable types:

1. **Basic Types**
   - `float` - Floating point numbers
   - `integer` - Integer values
   - `string` - Text strings
   - `boolean` - True/false values

2. **Advanced Types**
   - `choice` - Enumeration with allowed values
   - `module` - DSPy module selection
   - `embedding` - Vector representations
   - `tensor` - Multi-dimensional arrays

## Serialization

### Using protobuf Any

The protocol uses `google.protobuf.Any` for variable values and tool parameters. This allows type-safe serialization of various data types:

- **Simple types** (int, float, string, bool) - Use corresponding protobuf wrapper types
- **Complex types** (lists, dicts, tensors) - JSON-encode and wrap in StringValue
- **Custom types** - Define custom protobuf messages as needed

### Example Serialization

```python
# Python example
from google.protobuf import any_pb2
from google.protobuf.wrappers_pb2 import StringValue, DoubleValue

# Simple type
float_value = DoubleValue(value=0.7)
any_value = any_pb2.Any()
any_value.Pack(float_value)

# Complex type (JSON)
import json
complex_data = {"choices": ["A", "B", "C"], "weights": [0.3, 0.5, 0.2]}
json_value = StringValue(value=json.dumps(complex_data))
any_value = any_pb2.Any()
any_value.Pack(json_value)
```

## Code Generation

### For Elixir

```bash
# From snakepit directory
mix grpc.gen
```

This generates Elixir modules in `lib/snakepit/grpc/generated/`

### For Python

```bash
cd priv/python
python -m grpc_tools.protoc \
  -I../proto \
  --python_out=snakepit_bridge/grpc \
  --pyi_out=snakepit_bridge/grpc \
  --grpc_python_out=snakepit_bridge/grpc \
  ../proto/snakepit_bridge.proto
```

This generates Python modules in `snakepit_bridge/grpc/`

## Message Details

### Session Management

- **InitializeSessionRequest**: Contains session ID, metadata, and configuration
- **SessionConfig**: Configures caching, TTL, and telemetry
- **InitializeSessionResponse**: Returns available tools and initial variables

### Variable Messages

- **Variable**: Complete variable representation with ID, name, type, value, constraints, metadata, source, version, and optimization status
- **VariableUpdate**: Streamed update containing variable changes with metadata and timestamp

### Tool Messages

- **ToolSpec**: Tool definition with parameters, metadata, and streaming support
- **ExecuteToolRequest**: Tool execution request with parameters and metadata
- **ToolChunk**: Streaming chunk for progressive tool results

## Error Handling

All response messages include:
- `success` - Boolean indicating operation success
- `error_message` - Human-readable error description when success=false

## Versioning

Variables support optimistic locking through version numbers:
- Each variable has a `version` field incremented on updates
- `SetVariableRequest` includes `expected_version` for conflict detection

## Streaming

The protocol supports server-side streaming for:
- Tool execution results (`ExecuteStreamingTool`)
- Variable updates (`WatchVariables`)

Clients should handle stream termination and reconnection as needed.

## Security Considerations

1. **Session Isolation**: All operations require a valid session_id
2. **Type Validation**: All values are validated against their declared types
3. **Access Control**: Future support via `access_control_json` field
4. **Rate Limiting**: Should be implemented at the gRPC interceptor level

## Migration Notes

This protocol unifies the previously separate tool and variable bridges:
- Tool execution remains largely unchanged
- Variable operations are new additions
- All operations now go through the same gRPC channel
- Sessions provide isolation and state management