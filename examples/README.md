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