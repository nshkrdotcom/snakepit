# Snakepit Bridge Protocol Documentation

## Overview

The `snakepit_bridge.proto` file defines the gRPC protocol for the Snakepit bridge, supporting session management, tool execution (including streaming), tool registration/discovery, and telemetry streaming.

## Protocol Version

- **Version**: 1.0.0
- **Package**: `snakepit.bridge`

## Service Definition

The `BridgeService` service provides the following RPC methods:

### Health & Session Management

- `Ping` - Health check endpoint
- `InitializeSession` - Initialize a new session with configuration
- `CleanupSession` - Clean up session resources
- `GetSession` - Get session details
- `Heartbeat` - Session keepalive

### Tool Execution

- `ExecuteTool` - Execute a tool synchronously (unary RPC)
- `ExecuteStreamingTool` - Execute a tool with streaming results (server streaming RPC)

### Tool Registration & Discovery

- `RegisterTools` - Register Python tools with the bridge
- `GetExposedElixirTools` - Discover tools exposed by Elixir
- `ExecuteElixirTool` - Call an Elixir-side tool from Python

### Telemetry

- `StreamTelemetry` - Bidirectional telemetry stream for metrics and tracing

## Binary Serialization

The protocol supports binary payloads for efficient handling of large data:

### Binary Fields

- `ExecuteToolRequest.binary_parameters` (field 6): Binary parameters for large inputs (images, audio, etc.)
- `ExecuteToolResponse.binary_result` (field 6): Binary result payload
- `ExecuteElixirToolResponse.binary_result` (field 6): Binary result for Elixir tool calls

### Format Convention

- `binary_*` fields are **opaque bytes**; producer and consumer must agree on format
- Use the `metadata` field to communicate content-type, encoding, or other format details
- Keys in `binary_parameters` should match parameter names

### Pickle Opt-In (Python)

By default, `binary_parameters` are passed as raw bytes to Python tools. To enable Python pickle deserialization for a specific parameter, set the metadata key:

```
metadata["binary_format:<param_name>"] = "pickle"
```

Example:
```python
# Elixir/client side - mark 'model_weights' for pickle deserialization
request = ExecuteToolRequest(
    tool_name="load_model",
    binary_parameters={"model_weights": pickled_bytes},
    metadata={"binary_format:model_weights": "pickle"}
)

# Python adapter receives: arguments["model_weights"] as deserialized object
```

Without this metadata key, `arguments["model_weights"]` would be raw `bytes`.

## Type System

### `Any` Encoding Convention

The protocol uses `google.protobuf.Any` in two ways:

1. **True protobuf packing** - Wrap values in protobuf wrapper types (DoubleValue, StringValue, etc.) and use `Any.Pack()`
2. **JSON bytes convention** - JSON-encode complex data and store raw bytes in `Any.value` with a custom type URL

For maximum compatibility, prefer the JSON bytes convention for complex types:

```python
import json
from google.protobuf import any_pb2

# JSON bytes convention (recommended for complex types)
any_msg = any_pb2.Any()
any_msg.type_url = "type.snakepit.bridge/json"
any_msg.value = json.dumps({"key": "value"}).encode("utf-8")
```

Reserved payload fields (used by the protocol):
- `protocol_version` - Wire protocol version
- `call_type` - RPC call type indicator
- `session_id` - Session identifier

Tool parameters and results use `google.protobuf.Any` for flexible typing:

1. **Simple types** (int, float, string, bool) - Use corresponding protobuf wrapper types
2. **Complex types** (lists, dicts) - JSON-encode and wrap in StringValue
3. **Binary data** - Use the dedicated `binary_parameters`/`binary_result` fields

### Example Serialization

```python
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
  --python_out=. \
  --pyi_out=. \
  --grpc_python_out=. \
  ../proto/snakepit_bridge.proto
```

This generates Python modules in `priv/python/`

## Message Details

### Session Management

- **InitializeSessionRequest**: Contains session ID, metadata, and configuration
- **SessionConfig**: Configures caching, TTL, and telemetry
- **InitializeSessionResponse**: Returns success status and available tools

### Tool Messages

- **ToolSpec**: Tool definition with name, description, parameters, metadata, and streaming support flag
- **ParameterSpec**: Parameter definition with name, type, description, required flag, default value, and validation
- **ExecuteToolRequest**: Tool execution request with session ID, tool name, parameters, metadata, and optional binary data
- **ExecuteToolResponse**: Result with success flag, result payload, error message, metadata, execution time, and optional binary result
- **ToolChunk**: Streaming chunk with chunk ID, data bytes, is_final flag, and metadata

### Telemetry Messages

- **TelemetryEvent**: Event with name parts, measurements, metadata, timestamp, and correlation ID
- **TelemetryControl**: Control message for toggle, sampling, or filtering
- **TelemetrySamplingUpdate**: Sampling rate and event patterns
- **TelemetryEventFilter**: Allow/deny lists for event filtering

## Error Handling

All response messages include:
- `success` - Boolean indicating operation success
- `error_message` - Human-readable error description when success=false

## Security Considerations

1. **Local deployment model**: The bridge is designed for trusted/local environments
2. **Session isolation**: All operations require a valid session_id
3. **No TLS by default**: Uses insecure channels (appropriate for same-host communication)

For remote/untrusted deployments, additional security measures (TLS, auth) would be needed.

## Roadmap

The following features are planned but not yet implemented:

- Variable management (get/set/watch variables)
- Dependency tracking between variables
- Optimization APIs (start/stop optimization, history, rollback)
- TLS and authentication support
