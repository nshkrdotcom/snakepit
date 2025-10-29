# Snakepit Examples

This directory contains working examples demonstrating Snakepit's features. All examples can be run directly with `elixir` or `mix run`.

## Quick Start

```bash
# Run any example directly
elixir examples/grpc_basic.exs

# Or with mix
mix run examples/grpc_basic.exs
```

## Examples by Category

### 📚 Basic Examples

#### `grpc_basic.exs`
**Basic gRPC usage patterns**
- Simple request/response patterns
- Ping, echo, and calculation commands
- Basic error handling

```bash
elixir examples/grpc_basic.exs
```

#### `grpc_streaming.exs`
**Pool scaling and concurrent execution**
- Worker pool initialization
- Concurrent request handling
- Pool statistics

```bash
# With custom pool size
elixir examples/grpc_streaming.exs 5
```

### 🔍 Session Management

#### `grpc_sessions.exs`
**Session-based execution with worker affinity**
- Creating and managing sessions
- Worker affinity for stateful operations
- Session cleanup

```bash
elixir examples/grpc_sessions.exs
```

### ⚡ Concurrency & Performance

#### `grpc_concurrent.exs`
**Concurrent execution patterns**
- Multiple concurrent workers
- Task-based parallelism
- Performance benchmarking

```bash
elixir examples/grpc_concurrent.exs
```

#### `grpc_advanced.exs`
**Advanced patterns and optimization**
- Complex workflows
- Performance tuning
- Resource management

```bash
elixir examples/grpc_advanced.exs
```

### 🔁 Streaming

#### `grpc_streaming_demo.exs`
**Real-time streaming demonstrations**
- Streaming responses
- Progress tracking
- Incremental results

```bash
elixir examples/grpc_streaming_demo.exs
```

#### `stream_progress_demo.exs`
**Progress reporting with streaming**
- Timed streaming updates
- Rich progress output
- Real-time feedback

```bash
elixir examples/stream_progress_demo.exs
```

### 🔄 Bidirectional Tools

#### `bidirectional_tools_demo.exs`
**Bidirectional tool execution**
- Elixir tools callable from Python
- Python tools callable from Elixir
- Tool registry and discovery

```bash
elixir examples/bidirectional_tools_demo.exs
```

#### `bidirectional_tools_demo_auto.exs`
**Automatic bidirectional tool demo**
- Automated tool bridge demonstration
- Complete workflow examples

```bash
elixir examples/bidirectional_tools_demo_auto.exs
```

### 🧵 Threading (v0.6.0+)

#### `threaded_profile_demo.exs`
**Multi-threaded worker profile**
- Thread-based parallelism (Python 3.13+)
- Concurrent request handling
- Capacity management

```bash
elixir examples/threaded_profile_demo.exs
```

---

## 🆕 New in v0.6.7: Telemetry & Observability

### 📊 Telemetry Basics

#### `telemetry_basic.exs` ⭐
**Introduction to Snakepit telemetry**
- Attaching telemetry handlers
- Receiving events from Python workers
- Bidirectional event streaming
- Python telemetry API (`emit()` and `span()`)

```bash
elixir examples/telemetry_basic.exs
```

**What you'll learn:**
- How to attach `:telemetry` handlers
- Listening to worker lifecycle events
- Capturing Python execution events
- Using the Python telemetry API

### 📈 Advanced Telemetry

#### `telemetry_advanced.exs` ⭐
**Advanced telemetry patterns**
- Correlation ID tracking across boundaries
- Performance monitoring and alerting
- Runtime telemetry control (sampling, toggling)
- Event aggregation and metrics

```bash
elixir examples/telemetry_advanced.exs
```

**What you'll learn:**
- Multi-event handlers with `attach_many`
- Tracking requests across Elixir/Python boundary
- Performance SLA monitoring
- Runtime control of telemetry sampling

### 🖥️ Production Monitoring

#### `telemetry_monitoring.exs` ⭐
**Production-ready monitoring patterns**
- Worker health monitoring
- Performance SLA tracking
- Error rate monitoring
- Queue depth alerting
- Real-time metrics dashboard

```bash
elixir examples/telemetry_monitoring.exs
```

**What you'll learn:**
- Setting up production monitoring
- Detecting worker health issues
- SLA violation alerting
- Building metrics dashboards

### 📉 Metrics Integration

#### `telemetry_metrics_integration.exs` ⭐
**Integrating with metrics systems**
- Prometheus integration patterns
- StatsD integration patterns
- Custom metrics exporters
- Real-time metrics visualization

```bash
elixir examples/telemetry_metrics_integration.exs
```

**What you'll learn:**
- Using `telemetry_metrics` for metric definitions
- Exporting to Prometheus/StatsD
- Creating custom exporters
- Common metric patterns (counters, gauges, histograms)

---

## 🆕 New in v0.6.7: Structured Errors

### ❌ Error Handling

#### `structured_errors.exs` ⭐
**New structured error types**
- `Snakepit.Error` struct with detailed context
- Error categories for better handling
- Python traceback propagation
- Pattern matching on errors

```bash
elixir examples/structured_errors.exs
```

**What you'll learn:**
- Understanding the new `Snakepit.Error` struct
- Pattern matching on error categories
- Extracting debugging information
- Handling Python exceptions

---

## 🔧 Utility Scripts

#### `mix_bootstrap.exs`
Bootstrap script for Mix-based applications

#### `run_examples.exs`
Helper script to run multiple examples

---

## Common Patterns

### Running with Custom Configuration

```elixir
# Custom pool size
elixir examples/grpc_streaming.exs 10

# Environment variables
SNAKEPIT_LOG_LEVEL=debug elixir examples/grpc_basic.exs
```

### Suppressing Logs

Most examples already suppress internal Snakepit logs for clean output. To enable debug logs:

```elixir
# In the example file, change:
Application.put_env(:snakepit, :log_level, :debug)
```

### Error Handling

All examples include proper error handling patterns:

```elixir
case Snakepit.execute("command", params) do
  {:ok, result} ->
    # Handle success
  {:error, %Snakepit.Error{} = error} ->
    # Handle structured error (v0.6.7+)
  {:error, reason} ->
    # Handle legacy error
end
```

## Telemetry Event Catalog

The telemetry examples demonstrate these event types:

### Infrastructure Events (Layer 1)
- `[:snakepit, :pool, :initialized]` - Pool initialization
- `[:snakepit, :pool, :worker, :spawned]` - Worker started
- `[:snakepit, :pool, :worker, :terminated]` - Worker stopped
- `[:snakepit, :pool, :queue, :enqueued]` - Request queued
- `[:snakepit, :session, :created]` - Session created

### Python Execution Events (Layer 2)
- `[:snakepit, :python, :call, :start]` - Command started
- `[:snakepit, :python, :call, :stop]` - Command completed
- `[:snakepit, :python, :call, :exception]` - Command failed
- `[:snakepit, :python, :tool, :execution, :start]` - Tool started
- `[:snakepit, :python, :tool, :execution, :stop]` - Tool completed
- `[:snakepit, :python, :tool, :result_size]` - Result size metric

### gRPC Bridge Events (Layer 3)
- `[:snakepit, :grpc, :call, :start]` - gRPC call initiated
- `[:snakepit, :grpc, :call, :stop]` - gRPC call completed
- `[:snakepit, :grpc, :stream, :opened]` - Stream opened
- `[:snakepit, :grpc, :connection, :established]` - Connection ready

See [`TELEMETRY.md`](../TELEMETRY.md) for the complete event catalog and integration patterns.

## Requirements

- Elixir 1.18+
- Erlang/OTP 27+
- Python 3.9+ with required packages:
  ```bash
  # Install from project root
  ./deps/snakepit/scripts/setup_python.sh

  # Or manually
  cd priv/python
  pip install -r requirements.txt
  ```

## Troubleshooting

### "Worker failed to start"
- Ensure Python dependencies are installed
- Check Python version (3.9+)
- Verify gRPC port is available (50051)

### "Connection refused"
- Workers may take a few seconds to start
- Increase timeouts in pool configuration
- Check for port conflicts

### "Module not found"
- Run examples from project root
- Ensure `Mix.install` points to correct path

### Telemetry events not received
- Check telemetry handlers are attached before execution
- Verify event names match the catalog
- Ensure pooling is enabled

## Contributing

When adding new examples:

1. Follow the existing pattern (shebang, config, Mix.install, module, run_as_script)
2. Include clear documentation in comments
3. Add error handling
4. Suppress unnecessary logs
5. Update this README

## Related Documentation

- [Main README](../README.md) - Project overview
- [TELEMETRY.md](../TELEMETRY.md) - Complete telemetry guide
- [CHANGELOG.md](../CHANGELOG.md) - Version history
- [Architecture docs](../docs/) - Technical details

## Need Help?

- 📖 [Documentation](https://hexdocs.pm/snakepit)
- 💬 [GitHub Issues](https://github.com/nshkrdotcom/snakepit/issues)
- 🐛 [Bug Reports](https://github.com/nshkrdotcom/snakepit/issues/new)
