# Snakepit Examples

This directory contains working examples demonstrating Snakepit's features. Run from the project root with `mix run` (or `--no-start` if you prefer); each script restarts Snakepit as needed so it can set `:grpc_port` and `:pooling_enabled` safely.

## Quick Start

```bash
mix run examples/grpc_basic.exs
```

## Run Everything

```bash
# From repo root
./examples/run_all.sh

# Or bootstrap first
./examples/run_all.sh --setup

# Extend demo run time if needed (ms)
SNAKEPIT_EXAMPLE_DURATION_MS=8000 ./examples/run_all.sh

# Override just the bidirectional auto-demo duration (ms)
SNAKEPIT_AUTO_DEMO_DURATION_MS=8000 ./examples/run_all.sh

# Override loadtest worker counts
LOADTEST_BASIC_WORKERS=25 LOADTEST_SUSTAINED_WORKERS=10 ./examples/run_all.sh

# Shorten sustained load demo duration (ms) for faster runs
SNAKEPIT_SUSTAINED_DURATION_MS=10000 ./examples/run_all.sh

# Increase or disable per-example timeout (ms, set 0 to disable)
SNAKEPIT_RUN_TIMEOUT_MS=240000 ./examples/run_all.sh
```

Options:
- `--skip-showcase` / `--skip-loadtest` to skip the demo apps
- `--skip-doctor` to skip the environment check

## Examples by Category

### 📚 Basic Examples

#### `grpc_basic.exs`
**Basic gRPC usage patterns**
- Simple request/response patterns
- Ping, echo, and calculation commands
- Basic error handling

```bash
mix run --no-start examples/grpc_basic.exs
```

#### `grpc_streaming.exs`
**Pool scaling and concurrent execution**
- Worker pool initialization
- Concurrent request handling
- Pool statistics

```bash
# With custom pool size
mix run --no-start examples/grpc_streaming.exs 5
```

### 🔍 Session Management

#### `grpc_sessions.exs`
**Session-based execution with worker affinity**
- Creating and managing sessions
- Worker affinity for stateful operations
- Session cleanup

```bash
mix run --no-start examples/grpc_sessions.exs
```

### ⚡ Concurrency & Performance

#### `grpc_concurrent.exs`
**Concurrent execution patterns**
- Multiple concurrent workers
- Task-based parallelism
- Performance benchmarking

```bash
mix run --no-start examples/grpc_concurrent.exs
```

#### `grpc_advanced.exs`
**Advanced patterns and optimization**
- Complex workflows
- Performance tuning
- Resource management

```bash
mix run --no-start examples/grpc_advanced.exs
```

### 🔁 Streaming

#### `grpc_streaming_demo.exs`
**Real-time streaming demonstrations**
- Streaming responses
- Progress tracking
- Incremental results

```bash
mix run --no-start examples/grpc_streaming_demo.exs
```

#### `stream_progress_demo.exs`
**Progress reporting with streaming**
- Timed streaming updates
- Rich progress output
- Real-time feedback

```bash
mix run --no-start examples/stream_progress_demo.exs
```

#### `execute_streaming_tool_demo.exs`
**Pool-based streaming tool execution**
- Uses `Snakepit.execute_stream/3` (Pool → Worker path)
- Streaming-enabled Python tools
- Real-time chunk processing with callbacks
- See guides/streaming.md for BridgeServer streaming (v0.8.5+)

```bash
mix run --no-start examples/execute_streaming_tool_demo.exs
```

### 🔄 Bidirectional Tools

#### `bidirectional_tools_demo.exs`
**Bidirectional tool execution**
- Elixir tools callable from Python
- Python tools callable from Elixir
- Tool registry and discovery
- Set `SNAKEPIT_EXAMPLE_DURATION_MS` (or `SNAKEPIT_DEMO_DURATION_MS`) to auto-stop in scripted runs

```bash
mix run --no-start examples/bidirectional_tools_demo.exs
```

#### `bidirectional_tools_demo_auto.exs`
**Automatic bidirectional tool demo**
- Automated tool bridge demonstration
- Complete workflow examples

```bash
mix run --no-start examples/bidirectional_tools_demo_auto.exs
```

### 🧵 Threading (v0.6.0+)

#### `threaded_profile_demo.exs`
**Multi-threaded worker profile**
- Thread-based parallelism (Python 3.13+)
- Concurrent request handling
- Capacity management

```bash
mix run --no-start examples/threaded_profile_demo.exs
```

---

## 🆕 Prime Runtime (v0.7.4)

#### `structured_errors.exs`
**Structured exception translation**
- Pattern-matchable Python exceptions
- Callsite context + traceback metadata
- Legacy error compatibility

```bash
mix run --no-start examples/structured_errors.exs
```

---

## 🆕 New in v0.8.0: ML Workload Features

### 🖥️ Hardware Detection

#### `hardware_detection.exs`
**Automatic hardware detection for ML workloads**
- CPU, NVIDIA CUDA, Apple MPS, and AMD ROCm detection
- Capability flags and feature detection
- Device selection with fallback strategies
- Hardware identity for reproducible environments

```bash
mix run --no-start examples/hardware_detection.exs
```

**What you'll learn:**
- Detecting available accelerators automatically
- Checking hardware capabilities (CUDA, AVX2, etc.)
- Selecting devices with preference lists
- Generating hardware identity for lock files

### 🔒 Crash Recovery

#### `crash_recovery.exs`
**Fault tolerance patterns for ML workloads**
- Circuit breaker for preventing cascading failures
- Health monitoring with crash pattern tracking
- Retry policies with exponential backoff
- Executor helpers for protected execution

```bash
mix run --no-start examples/crash_recovery.exs
```

**What you'll learn:**
- Using circuit breakers to protect external calls
- Monitoring worker health and crash patterns
- Configuring retry policies with jitter
- Combining multiple protection strategies

### 🐛 ML Error Handling

#### `ml_errors.exs`
**Structured exception handling for ML operations**
- Shape mismatch errors with dimension detection
- Device mismatch errors with transfer suggestions
- Out of memory errors with recovery suggestions
- Parsing Python errors into structured exceptions

```bash
mix run --no-start examples/ml_errors.exs
```

**What you'll learn:**
- Creating and handling ML-specific exceptions
- Parsing Python errors into Elixir structs
- Pattern matching on different error types
- Extracting shapes and memory values from messages

### 📊 ML Telemetry

#### `ml_telemetry.exs`
**ML-specific telemetry and observability**
- Hardware detection telemetry events
- GPU profiler for memory/utilization sampling
- Span helpers for timing operations
- Prometheus-compatible metric definitions

```bash
mix run --no-start examples/ml_telemetry.exs
```

**What you'll learn:**
- ML telemetry event catalog
- Using span helpers for timing
- Prometheus metrics for ML workloads
- Emitting custom GPU/error events

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
mix run --no-start examples/telemetry_basic.exs
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
mix run --no-start examples/telemetry_advanced.exs
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
mix run --no-start examples/telemetry_monitoring.exs
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
mix run --no-start examples/telemetry_metrics_integration.exs
```

**What you'll learn:**
- Using `telemetry_metrics` for metric definitions
- Exporting to Prometheus/StatsD
- Creating custom exporters
- Common metric patterns (counters, gauges, histograms)

---

## 🔧 Utility Scripts

#### `mix_bootstrap.exs`
Bootstrap script for Mix-based applications

#### `run_examples.exs`
Helper script to run multiple examples

#### `run_all.sh`
Runs every example (scripts + demo apps) via `mix run`

## Example Apps

### `examples/snakepit_showcase`
Run the showcase app with `mix run`:

```bash
cd examples/snakepit_showcase
mix setup
mix run --eval 'Snakepit.run_as_script(fn -> SnakepitShowcase.DemoRunner.run_all() end, exit_mode: :auto)'
```

### `examples/snakepit_loadtest`
Run the load tests with `mix run`:

```bash
cd examples/snakepit_loadtest
mix setup
mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.BasicLoadDemo.run(10) end, exit_mode: :auto)'
mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.StressTestDemo.run(10) end, exit_mode: :auto)'
mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.BurstLoadDemo.run(10) end, exit_mode: :auto)'
mix run --eval 'Snakepit.run_as_script(fn -> SnakepitLoadtest.Demos.SustainedLoadDemo.run(5) end, exit_mode: :auto)'
```

---

## Common Patterns

### Example Wrapper

Examples use `Snakepit.Examples.Bootstrap.run_example/2`, which wraps `Snakepit.run_as_script/2`,
awaits the pool when enabled, and defaults to `exit_mode: :auto` (unless `exit_mode` or legacy
`:halt` is set). `stop_mode` defaults to `:if_started`.
Use `await_pool: false` for docs-only or gRPC-only demos.

### Running with Custom Configuration

```elixir
# Custom pool size
mix run --no-start examples/grpc_streaming.exs 10

# Environment variables
SNAKEPIT_LOG_LEVEL=debug mix run --no-start examples/grpc_basic.exs
```

### Logging

Most examples run with `log_level: :error` for clean output. To enable verbose logs:

```elixir
# In the example file, change:
Application.put_env(:snakepit, :log_level, :debug)
Application.put_env(:snakepit, :log_categories, [:grpc, :pool])
```

### Error Handling

All examples include proper error handling patterns:

```elixir
case Snakepit.execute("command", params) do
  {:ok, result} ->
    # Handle success
  {:error, %Snakepit.Error.ValueError{} = error} ->
    # Handle mapped Python ValueError (v0.7.4+)
  {:error, %Snakepit.Error.PythonException{} = error} ->
    # Handle unmapped Python exceptions
  {:error, %Snakepit.Error{} = error} ->
    # Handle Snakepit runtime error
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

### ML Workload Events (v0.8.0+)
- `[:snakepit, :hardware, :detect, :start]` - Hardware detection started
- `[:snakepit, :hardware, :detect, :stop]` - Hardware detection completed
- `[:snakepit, :hardware, :select, :start]` - Device selection started
- `[:snakepit, :hardware, :select, :stop]` - Device selection completed
- `[:snakepit, :circuit_breaker, :opened]` - Circuit breaker opened
- `[:snakepit, :circuit_breaker, :closed]` - Circuit breaker closed
- `[:snakepit, :circuit_breaker, :half_open]` - Circuit breaker half-open
- `[:snakepit, :retry, :attempt]` - Retry attempt made
- `[:snakepit, :retry, :success]` - Retry succeeded
- `[:snakepit, :retry, :exhausted]` - Retries exhausted
- `[:snakepit, :error, :shape_mismatch]` - Shape mismatch error
- `[:snakepit, :error, :device]` - Device error
- `[:snakepit, :error, :oom]` - Out of memory error
- `[:snakepit, :gpu, :memory, :sampled]` - GPU memory sampled
- `[:snakepit, :gpu, :utilization, :sampled]` - GPU utilization sampled

See [`TELEMETRY.md`](../TELEMETRY.md) for the complete event catalog and integration patterns.

## Requirements

- Elixir 1.18+
- Erlang/OTP 27+
- Python 3.9+ with required packages:
  ```bash
  # From project root
  mix snakepit.setup
  mix snakepit.doctor
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
- Ensure `mix_bootstrap.exs` is present and referenced

### Telemetry events not received
- Check telemetry handlers are attached before execution
- Verify event names match the catalog
- Ensure pooling is enabled

## Contributing

When adding new examples:

1. Follow the existing pattern (shebang, mix_bootstrap, config, module, run_example)
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
