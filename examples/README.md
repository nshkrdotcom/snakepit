# Snakepit gRPC Examples

This directory contains examples demonstrating the unified gRPC architecture of Snakepit. All examples use the `Snakepit.Adapters.GRPCPython` adapter for consistent behavior.

## Examples Overview

### 1. **grpc_basic.exs**
Basic request/response patterns with gRPC:
- Simple commands (ping, echo, compute)
- Error handling
- Custom timeouts
- Pool configuration

```bash
elixir examples/grpc_basic.exs
```

### 2. **grpc_sessions.exs**
Session management with worker affinity:
- Session initialization
- Variable registration in sessions
- State persistence across calls
- Session cleanup

```bash
elixir examples/grpc_sessions.exs
```

### 3. **grpc_streaming.exs** / **grpc_streaming_demo.exs**
Real-time streaming operations:
- Progress tracking
- Chunked data processing
- Error handling in streams
- Parallel streaming

```bash
elixir examples/grpc_streaming.exs
# or with custom pool size
elixir examples/grpc_streaming_demo.exs 8
```

### 4. **grpc_variables.exs**
Type-safe variable management:
- Variable registration with types
- Constraints and validation
- Batch operations
- Pattern matching and filtering

```bash
elixir examples/grpc_variables.exs
```

### 5. **grpc_concurrent.exs**
Parallel execution and pool utilization:
- Concurrent task execution
- Pool saturation testing
- Mixed operation types
- Performance benchmarking

```bash
elixir examples/grpc_concurrent.exs
```

### 6. **grpc_advanced.exs**
Complex workflows and patterns:
- Pipeline execution
- State management
- Error recovery with retry
- Event-driven processing
- Resource management

```bash
elixir examples/grpc_advanced.exs
```

### 7. **variable_usage.py**
Python client example:
- Direct gRPC client usage
- SessionContext API
- Variable proxies
- Batch operations

```bash
python examples/variable_usage.py
```

### 8. **bidirectional_tools_demo.exs**
Demonstrates Elixir tools exposed to Python:
- Registering Elixir functions as tools
- Tool discovery and metadata
- Direct tool execution
- Integration with Python adapters

```bash
elixir examples/bidirectional_tools_demo.exs
```

### 9. **python_elixir_tools_demo.py**
Python calling Elixir tools:
- Discovering available Elixir tools
- Direct tool execution via gRPC
- Using tool proxies for seamless integration
- Hybrid Python-Elixir processing

```bash
# Option 1: Interactive demo (prompts for input)
elixir examples/bidirectional_tools_demo.exs

# Option 2: Auto-run server (recommended)
# Terminal 1 - Start the Elixir server:
elixir examples/bidirectional_tools_demo_auto.exs

# Terminal 2 - Run the Python client:
python examples/python_elixir_tools_demo.py
# When prompted, just press Enter to use the default session ID
```

## Running the Examples

1. **Prerequisites**:
   ```bash
   # Install Elixir dependencies
   mix deps.get
   
   # Install Python dependencies
   cd priv/python
   pip install -r requirements.txt
   ```

2. **Start with basic examples** to understand core concepts:
   ```bash
   elixir examples/grpc_basic.exs
   elixir examples/grpc_sessions.exs
   ```

3. **Explore advanced features**:
   ```bash
   elixir examples/grpc_streaming.exs
   elixir examples/grpc_concurrent.exs
   ```

## Important: Process Cleanup

All example scripts use `Snakepit.run_as_script/2` to ensure proper cleanup:
- Pool initialization is deterministic (no race conditions)
- All Python processes are terminated when the script exits
- No orphaned processes remain after completion

This is handled automatically - you don't need to worry about manual cleanup!

## Common Configuration

All examples use similar configuration:

```elixir
# Enable gRPC adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

# Enable pooling
Application.put_env(:snakepit, :pooling_enabled, true)

# Configure pool size
Application.put_env(:snakepit, :pool_config, %{pool_size: 4})

# Configure gRPC port
Application.put_env(:snakepit, :grpc_port, 50051)
```

## Architecture

The examples demonstrate Snakepit's unified gRPC architecture:

- **gRPC Communication**: All communication uses HTTP/2 with Protocol Buffers
- **Stateless Python Servers**: Python processes are stateless, with state managed by Elixir
- **Session Management**: Centralized session store in Elixir with worker affinity
- **Streaming Support**: Native gRPC streaming for real-time updates
- **Type Safety**: Strong typing through Protocol Buffers and variable constraints
- **Bidirectional Tool Bridge**: Seamless execution of tools across language boundaries

## Bidirectional Tool Bridge

The tool bridge examples (8 & 9) showcase Snakepit's advanced capability for cross-language tool execution:

### Key Features:
- **Tool Discovery**: Both Elixir and Python can discover available tools from the other side
- **Transparent Proxying**: Tools appear as native functions in the calling language
- **Type Safety**: Parameter specifications and validation across languages
- **Session Integration**: Tools are scoped to sessions for proper isolation

### Usage Pattern:
1. **Elixir exposes tools** by registering them with `exposed_to_python: true`
2. **Python discovers tools** automatically when creating a SessionContext
3. **Tools are called** like regular functions with automatic serialization
4. **Results flow back** with proper type conversion

### Example Workflow:
```python
# Python side
ctx = SessionContext(stub, session_id)

# Elixir tools appear as Python functions
result = ctx.elixir_tools["parse_json"](json_string='{"test": true}')

# Or use direct call
result = ctx.call_elixir_tool("calculate_fibonacci", n=20)
```

This enables powerful patterns where each language handles what it does best!

## Troubleshooting

If examples fail to run:

1. **Check Python dependencies**:
   ```bash
   python -c "import grpcio, protobuf; print('gRPC OK')"
   ```

2. **Check Elixir application**:
   ```bash
   iex -S mix
   iex> Application.ensure_all_started(:snakepit)
   ```

3. **Verify gRPC server**:
   - The Elixir gRPC server should start on port 50051
   - Python workers connect back to this server

4. **Enable debug logging**:
   ```elixir
   Logger.configure(level: :debug)
   ```