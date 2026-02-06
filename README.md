# Snakepit

<div align="center">
  <img src="assets/snakepit-logo.svg" alt="Snakepit Logo" width="200" height="200">
</div>

> A high-performance, generalized process pooler and session manager for external language integrations in Elixir

[![Hex Version](https://img.shields.io/hexpm/v/snakepit.svg)](https://hex.pm/packages/snakepit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/snakepit)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/Elixir-1.18%2B-purple.svg)](https://elixir-lang.org)

## Features

- **High-performance process pooling** with concurrent worker initialization
- **Session affinity** for stateful operations across requests (hint by default, strict modes available)
- **gRPC streaming** for real-time progress updates and large data transfers
- **Bidirectional tool bridge** allowing Python to call Elixir functions and vice versa
- **Production-ready process management** with automatic orphan cleanup
- **Hardware detection** for ML accelerators (CUDA, MPS, ROCm)
- **Fault tolerance** with circuit breakers, retry policies, and crash barriers
- **Comprehensive telemetry** with OpenTelemetry support
- **Dual worker profiles** (process isolation or threaded parallelism)
- **Zero-copy data interop** via DLPack and Arrow

## Installation

Add `snakepit` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:snakepit, "~> 0.13.0"}
  ]
end
```

Then run:

```bash
mix deps.get
mix snakepit.setup    # Install Python dependencies and generate gRPC stubs
mix snakepit.doctor   # Verify environment is correctly configured
```

### Using with SnakeBridge (Recommended)

For higher-level Python integration with compile-time type generation, use [SnakeBridge](https://hex.pm/packages/snakebridge) instead of snakepit directly. SnakeBridge handles Python environment setup automatically at compile time.

```elixir
def deps do
  [{:snakebridge, "~> 0.15.0"}]
end

def project do
  [
    ...
    compilers: [:snakebridge] ++ Mix.compilers()
  ]
end
```

## Quick Start

```elixir
# Execute a command on any available worker
{:ok, result} = Snakepit.execute("ping", %{})

# Execute with session affinity (prefer the same worker for related requests)
{:ok, result} = Snakepit.execute_in_session("session_123", "process_data", %{input: data})

# Stream results for long-running operations
Snakepit.execute_stream("batch_process", %{items: items}, fn chunk ->
  IO.puts("Progress: #{chunk["progress"]}%")
end)
```

## Configuration

### Simple Configuration

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "your_adapter_module"],
  pool_size: 10,
  log_level: :error
```

### Multi-Pool Configuration (v0.6+)

```elixir
config :snakepit,
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 10,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "my_app.adapters.MainAdapter"]
    },
    %{
      name: :compute,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 8,
      adapter_args: ["--adapter", "my_app.adapters.ComputeAdapter"]
    }
  ]
```

### Logging Configuration

Snakepit is silent by default (errors only):

```elixir
config :snakepit, log_level: :error          # Default - errors only
config :snakepit, log_level: :info           # Include info messages
config :snakepit, log_level: :debug          # Verbose debugging
config :snakepit, log_level: :none           # Complete silence

# Filter to specific categories
config :snakepit, log_level: :debug, log_categories: [:grpc, :pool]
```

### gRPC Listener Configuration

By default, Snakepit runs an internal-only gRPC listener on an ephemeral port
and publishes the assigned port to Python workers at runtime:

```elixir
config :snakepit,
  grpc_listener: %{
    mode: :internal
  }
```

Explicit external bindings are opt-in and require host/port configuration:

```elixir
config :snakepit,
  grpc_listener: %{
    mode: :external,
    host: "localhost",
    bind_host: "0.0.0.0",
    port: 50051
  }
```

For multi-instance deployments sharing a host, use the pooled external mode:

```elixir
config :snakepit,
  grpc_listener: %{
    mode: :external_pool,
    host: "localhost",
    bind_host: "0.0.0.0",
    base_port: 50051,
    pool_size: 32
  }
```

To isolate process registry state when sharing a deployment directory, set
an explicit instance name, instance token, and data directory:

```elixir
config :snakepit,
  instance_name: "my-app-a",
  instance_token: "node-a-01",
  data_dir: "/var/lib/snakepit"
```

`instance_name` identifies an environment (for example `prod-us-east-1`).
`instance_token` identifies one running instance inside that environment.
When running multiple Snakepit VMs from the same checkout or host at the same
time, each VM must use a unique `instance_token` so cleanup logic never targets
another live instance.

Environment variables are also supported:

```bash
SNAKEPIT_INSTANCE_NAME=my-app SNAKEPIT_INSTANCE_TOKEN=job_1 mix run --no-start script_a.exs
SNAKEPIT_INSTANCE_NAME=my-app SNAKEPIT_INSTANCE_TOKEN=job_2 mix run --no-start script_b.exs
```

### Runtime Configurable Defaults

All hardcoded timeout and sizing values are now configurable via `Application.get_env/3`.
Values are read at runtime, allowing configuration changes without recompilation.

```elixir
# config/runtime.exs - Example customization
config :snakepit,
  # Timeouts (all in milliseconds)
  default_command_timeout: 30_000,       # Default timeout for commands
  pool_request_timeout: 60_000,          # Pool execute timeout
  pool_streaming_timeout: 300_000,       # Pool streaming timeout
  pool_startup_timeout: 10_000,          # Worker startup timeout
  pool_queue_timeout: 5_000,             # Queue timeout
  checkout_timeout: 5_000,               # Worker checkout timeout
  grpc_worker_execute_timeout: 30_000,   # GRPCWorker execute timeout
  grpc_worker_stream_timeout: 300_000,   # GRPCWorker streaming timeout
  graceful_shutdown_timeout_ms: 6_000,   # Python process shutdown timeout

  # Pool sizing
  pool_max_queue_size: 1000,             # Max pending requests in queue
  pool_max_workers: 150,                 # Maximum workers per pool
  pool_startup_batch_size: 10,           # Workers started per batch
  pool_startup_batch_delay_ms: 500,      # Delay between startup batches

  # Pool recovery
  pool_reconcile_interval_ms: 1_000,     # Reconcile worker count interval (0 disables)
  pool_reconcile_batch_size: 2,          # Max workers respawned per tick

  # Worker supervisor restart intensity
  worker_starter_max_restarts: 3,
  worker_starter_max_seconds: 5,
  worker_supervisor_max_restarts: 3,
  worker_supervisor_max_seconds: 5,

  # Retry policy
  retry_max_attempts: 3,
  retry_backoff_sequence: [100, 200, 400, 800, 1600],
  retry_max_backoff_ms: 30_000,
  retry_jitter_factor: 0.25,

  # Circuit breaker
  circuit_breaker_failure_threshold: 5,
  circuit_breaker_reset_timeout_ms: 30_000,
  circuit_breaker_half_open_max_calls: 1,

  # Crash barrier
  crash_barrier_taint_duration_ms: 60_000,
  crash_barrier_max_restarts: 1,
  crash_barrier_backoff_ms: [50, 100, 200],

  # Health monitor
  health_monitor_check_interval: 30_000,
  health_monitor_crash_window_ms: 60_000,
  health_monitor_max_crashes: 10,

  # Heartbeat
  heartbeat_ping_interval_ms: 2_000,
  heartbeat_timeout_ms: 10_000,
  heartbeat_max_missed: 3,

  # Session store
  session_cleanup_interval: 60_000,
  session_default_ttl: 3600,
  session_max_sessions: 10_000,
  session_warning_threshold: 0.8,

  # gRPC listener
  grpc_listener: %{mode: :internal},
  grpc_internal_host: "127.0.0.1",
  grpc_port_pool_size: 32,
  grpc_listener_ready_timeout_ms: 5_000,
  grpc_listener_port_check_interval_ms: 25,
  grpc_listener_reuse_attempts: 3,
  grpc_listener_reuse_wait_timeout_ms: 500,
  grpc_listener_reuse_retry_delay_ms: 100,
  grpc_num_acceptors: 20,
  grpc_max_connections: 1000,
  grpc_socket_backlog: 512
```

See `Snakepit.Defaults` module documentation for the complete list of configurable values.

## Core API

### Basic Execution

```elixir
# Simple command execution
{:ok, result} = Snakepit.execute("command_name", %{param: "value"})

# With timeout
{:ok, result} = Snakepit.execute("slow_command", %{}, timeout: 30_000)

# Target specific pool
{:ok, result} = Snakepit.execute("ml_inference", %{}, pool: :compute)
```

### Session Affinity

Sessions route related requests to the same worker when possible, enabling stateful operations:

```elixir
session_id = "user_#{user.id}"

# First call establishes worker affinity
{:ok, _} = Snakepit.execute_in_session(session_id, "load_model", %{model: "gpt-4"})

# Subsequent calls prefer the same worker
{:ok, result} = Snakepit.execute_in_session(session_id, "generate", %{prompt: "Hello"})
{:ok, result} = Snakepit.execute_in_session(session_id, "generate", %{prompt: "Continue"})
```

By default, affinity is a hint. If the preferred worker is busy or tainted, Snakepit can fall back to another worker. For strict pinning, configure affinity modes at the pool level:

```elixir
config :snakepit,
  pools: [
    %{name: :default, pool_size: 4, affinity: :strict_queue},
    %{name: :latency_sensitive, pool_size: 4, affinity: :strict_fail_fast}
  ]
```

- `:strict_queue` queues requests for the preferred worker when it is busy.
- `:strict_fail_fast` returns `{:error, :worker_busy}` when the preferred worker is busy.
- If the preferred worker is tainted or missing, strict modes return `{:error, :session_worker_unavailable}`.

### Streaming Operations

```elixir
# Stream with callback for progress updates
Snakepit.execute_stream("train_model", %{epochs: 100}, fn chunk ->
  case chunk do
    %{"type" => "progress", "epoch" => n, "loss" => loss} ->
      IO.puts("Epoch #{n}: loss=#{loss}")
    %{"type" => "complete", "model_path" => path} ->
      IO.puts("Training complete: #{path}")
  end
end)

# Stream with session affinity
Snakepit.execute_in_session_stream(session_id, "process_batch", %{}, fn chunk ->
  handle_chunk(chunk)
end)
```

### Pool Statistics

```elixir
# Get pool statistics
stats = Snakepit.get_stats()
# => %{requests: 1523, errors: 2, queued: 0, queue_timeouts: 0}

# List worker IDs
workers = Snakepit.list_workers()
# => ["worker_1", "worker_2", "worker_3"]

# Wait for pool to be ready (useful in tests)
:ok = Snakepit.Pool.await_ready(:default, 10_000)
```

## Worker Profiles

### Process Profile (Default)

One Python process per worker. Full process isolation, works with all Python versions.

```elixir
%{
  name: :default,
  worker_profile: :process,
  pool_size: 10,
  startup_batch_size: 4,      # Spawn 4 workers at a time
  startup_batch_delay_ms: 500 # Wait between batches
}
```

Best for: I/O-bound workloads, maximum isolation, Python < 3.13.

### Thread Profile (Python 3.13+)

Multiple threads within each Python process. Shared memory, true parallelism with free-threaded Python.

```elixir
%{
  name: :compute,
  worker_profile: :thread,
  pool_size: 4,
  threads_per_worker: 8,
  thread_safety_checks: true
}
```

Best for: CPU-bound ML workloads, large shared models, Python 3.13+ with free-threading.

## Hardware Detection

Snakepit detects available ML accelerators for intelligent device selection:

```elixir
# Detect all hardware
info = Snakepit.Hardware.detect()
# => %{accelerator: :cuda, cpu: %{cores: 8, ...}, cuda: %{devices: [...]}}

# Check capabilities
caps = Snakepit.Hardware.capabilities()
# => %{cuda: true, mps: false, rocm: false, avx2: true}

# Select device with fallback chain
{:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])
# => {:ok, {:cuda, 0}}

# Generate hardware identity for lock files
identity = Snakepit.Hardware.identity()
File.write!("hardware.lock", Jason.encode!(identity))
```

Supported accelerators: CPU (with AVX/AVX2/AVX-512 detection), NVIDIA CUDA, Apple MPS, AMD ROCm.

## Fault Tolerance

### Circuit Breaker

Prevents cascading failures by temporarily blocking requests after repeated failures:

```elixir
{:ok, cb} = Snakepit.CircuitBreaker.start_link(
  failure_threshold: 5,
  reset_timeout_ms: 30_000
)

# Execute through circuit breaker
case Snakepit.CircuitBreaker.call(cb, fn -> external_api_call() end) do
  {:ok, result} -> handle_result(result)
  {:error, :circuit_open} -> {:error, :service_unavailable}
  {:error, reason} -> {:error, reason}
end

# Check state
Snakepit.CircuitBreaker.state(cb)  # => :closed | :open | :half_open
```

### Retry Policies

```elixir
policy = Snakepit.RetryPolicy.new(
  max_attempts: 4,
  backoff_ms: [100, 200, 400, 800],
  jitter: true,
  retriable_errors: [:timeout, :unavailable]
)

# Use with Executor
Snakepit.Executor.execute_with_retry(
  fn -> flaky_operation() end,
  max_attempts: 3,
  backoff_ms: [100, 200, 400]
)
```

### Health Monitoring

```elixir
{:ok, hm} = Snakepit.HealthMonitor.start_link(
  pool: :default,
  max_crashes: 5,
  crash_window_ms: 60_000
)

Snakepit.HealthMonitor.healthy?(hm)  # => true | false
Snakepit.HealthMonitor.stats(hm)     # => %{total_crashes: 2, ...}
```

### Executor Helpers

```elixir
# With timeout
Snakepit.Executor.execute_with_timeout(fn -> slow_op() end, timeout_ms: 5000)

# With retry
Snakepit.Executor.execute_with_retry(fn -> flaky_op() end, max_attempts: 3)

# Combined retry + circuit breaker
Snakepit.Executor.execute_with_protection(circuit_breaker, fn ->
  risky_operation()
end, max_attempts: 3)

# Batch execution
Snakepit.Executor.execute_batch(
  [fn -> op1() end, fn -> op2() end, fn -> op3() end],
  max_concurrency: 2
)
```

## Python Adapters

### Creating an Adapter

Adapters follow a **per-request lifecycle**: a new instance is created for each RPC request,
`initialize()` is called at the start, the tool executes, then `cleanup()` is called (even on error).

```python
# my_adapter.py
from snakepit_bridge import BaseAdapter, tool

# Module-level cache for expensive resources (shared across requests)
_model_cache = {}

class MyAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        self.model = None

    def initialize(self):
        """Called at the start of each request."""
        # Load from cache or disk (cache persists across requests)
        if "model" not in _model_cache:
            _model_cache["model"] = load_model()
        self.model = _model_cache["model"]

    def cleanup(self):
        """Called at the end of each request (even on error)."""
        # Release request-specific resources (not the cached model)
        pass

    @tool(description="Run inference on input data")
    def predict(self, input_data: dict) -> dict:
        result = self.model.predict(input_data["text"])
        return {"prediction": result, "confidence": 0.95}

    @tool(description="Process with progress updates", supports_streaming=True)
    def batch_process(self, items: list):
        for i, item in enumerate(items):
            result = self.process_item(item)
            yield {"progress": (i + 1) / len(items) * 100, "result": result}
```

### Thread-Safe Adapters (Python 3.13+)

```python
import threading
from snakepit_bridge import ThreadSafeAdapter, tool, thread_safe_method

# Module-level shared resources (thread-safe access required)
_shared_model = None
_model_lock = threading.Lock()

class ThreadedAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.model = None

    def initialize(self):
        """Load shared model (with thread-safe initialization)."""
        global _shared_model
        with _model_lock:
            if _shared_model is None:
                _shared_model = load_model()
        self.model = _shared_model

    @tool
    @thread_safe_method
    def predict(self, text: str) -> dict:
        # Thread-local cache
        cache = self.get_thread_local("cache", default={})
        if text in cache:
            return cache[text]

        result = self.model.predict(text)
        cache[text] = result
        self.set_thread_local("cache", cache)
        return result

    @tool
    @thread_safe_method
    def update_config(self, config: dict):
        # Protect shared mutable state
        with self.acquire_lock():
            self.config.update(config)
```

### Session Context and Elixir Tool Calls

```python
@tool(description="Process using Elixir tools")
def hybrid_process(self, data: dict) -> dict:
    # Access session information
    session_id = self.session_context.session_id

    # Call a registered Elixir tool
    validation = self.session_context.call_elixir_tool(
        "validate_data",
        {"data": data, "schema": "user"}
    )

    if validation["valid"]:
        return self.process(data)
    else:
        return {"error": validation["errors"]}
```

## Bidirectional Tool Bridge

### Registering Elixir Tools

```elixir
# Register an Elixir function callable from Python
Snakepit.Bridge.ToolRegistry.register_elixir_tool(
  session_id,
  "calculate_hash",
  fn params ->
    hash = :crypto.hash(:sha256, params["data"]) |> Base.encode16()
    %{hash: hash, algorithm: "sha256"}
  end,
  %{
    description: "Calculate SHA256 hash of data",
    exposed_to_python: true
  }
)
```

### Calling from Python

```python
# Python adapter can call registered Elixir tools
result = self.session_context.call_elixir_tool("calculate_hash", {"data": "hello"})
# => {"hash": "2CF24DBA5FB0A30E...", "algorithm": "sha256"}

# Or use the proxy
hash_tool = self.session_context.elixir_tools["calculate_hash"]
result = hash_tool(data="hello")
```

## Telemetry & Observability

### Attaching Handlers

```elixir
# Worker lifecycle events
:telemetry.attach("worker-spawned", [:snakepit, :pool, :worker, :spawned], fn
  _event, %{duration: duration}, %{worker_id: id}, _config ->
    Logger.info("Worker #{id} spawned in #{duration}ms")
end, nil)

# Python execution events
:telemetry.attach("python-call", [:snakepit, :grpc_worker, :execute, :stop], fn
  _event, %{duration_ms: ms}, %{command: cmd}, _config ->
    Logger.info("#{cmd} completed in #{ms}ms")
end, nil)
```

### Python Telemetry API

```python
from snakepit_bridge import telemetry

# Emit custom events
telemetry.emit(
    "model.inference",
    measurements={"latency_ms": 45, "tokens": 128},
    metadata={"model": "gpt-4", "batch_size": 1}
)

# Automatic timing with spans
with telemetry.span("data_processing", {"stage": "preprocessing"}):
    processed = preprocess(data)  # Automatically timed
```

### OpenTelemetry Integration

```elixir
config :snakepit, :opentelemetry, %{enabled: true}
```

## Graceful Serialization

Snakepit gracefully handles Python objects that cannot be serialized to JSON. Instead of
failing, non-serializable objects are replaced with informative markers containing type
information.

### How It Works

When Python returns data containing non-JSON-serializable objects:

1. **Conversion attempted first**: Objects with common conversion methods (`model_dump`,
   `to_dict`, `_asdict`, `tolist`, `isoformat`) are automatically converted
2. **Marker fallback**: Truly non-serializable objects become marker maps with type info

```elixir
# Returns with some fields as markers
{:ok, result} = Snakepit.execute("get_complex_data", %{})

# Check for markers in the response
if Snakepit.Serialization.unserializable?(result["response"]) do
  {:ok, info} = Snakepit.Serialization.unserializable_info(result["response"])
  Logger.warning("Got unserializable object: #{info.type}")
end
```

### Marker Format

Unserializable markers are maps with the structure:

```elixir
%{
  "__ffi_unserializable__" => true,
  "__type__" => "module.ClassName"
}
```

By default, markers only include type information (safe for production). The `__repr__`
field is optionally included when explicitly enabled.

### Configuration

Control marker detail level via environment variables (set before starting workers):

```elixir
# In config/runtime.exs or application startup
System.put_env("SNAKEPIT_UNSERIALIZABLE_DETAIL", "repr_redacted_truncated")
System.put_env("SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN", "200")
```

Available detail modes:
- `none` (default) - Only type, no repr (safe for production)
- `type` - Placeholder string with type name
- `repr_truncated` - Include truncated repr (may leak secrets)
- `repr_redacted_truncated` - Truncated repr with common secrets redacted

### Size Guards

Large array conversions are guarded to prevent payload bloat:

```bash
# Limit list expansion (default: 1,000,000 elements)
export SNAKEPIT_TOLIST_MAX_ELEMENTS=100000
```

Size is checked **before** calling `tolist()` for known types:
- **numpy.ndarray**: Precise detection via `isinstance()`
- **scipy sparse / pandas**: Best-effort heuristics

For unknown types, `tolist()` is called but the result size is checked before transmission.
When a result exceeds the threshold, it falls back to a marker instead of sending
potentially gigabytes of data.

See `Snakepit.Serialization` module and `guides/graceful-serialization.md` for full details.

## Process Management

### ETS Table Ownership

Snakepit uses ETS tables for high-performance shared state (worker taint tracking,
zero-copy handles). These tables are owned by `Snakepit.ETSOwner`, a dedicated GenServer
that ensures tables persist for the application lifetime.

This design prevents a common pitfall: if a short-lived process creates an ETS table,
the table is destroyed when that process exits. ETSOwner solves this by centralizing
table ownership in a long-lived supervisor child.

Managed tables:
- `:snakepit_worker_taints` - Crash barrier taint tracking
- `:snakepit_zero_copy_handles` - DLPack/Arrow handle registry

See `Snakepit.ETSOwner` module documentation and `lib/snakepit/supervisor_tree.md`
for details.

### Automatic Cleanup

Snakepit automatically tracks and cleans up Python processes:

- Each BEAM run gets a unique run ID stored in process registry
- On application restart, orphaned processes from previous runs are killed
- Graceful shutdown sends SIGTERM, followed by SIGKILL if needed

### Manual Cleanup

```elixir
# Force cleanup of all worker processes
Snakepit.cleanup()
```

### Script Mode

For Mix tasks and scripts, use `run_as_script/2` for automatic lifecycle management:

```elixir
Snakepit.run_as_script(fn ->
  {:ok, result} = Snakepit.execute("process_data", %{})
  IO.inspect(result)
end, exit_mode: :auto)
```

`exit_mode` controls VM exit behavior (default: `:none`); `stop_mode` controls whether
Snakepit itself stops (default: `:if_started`). For embedded usage, keep `exit_mode: :none` and set
`stop_mode: :never` to avoid stopping the host application.

Warning: `exit_mode: :halt` or `:stop` terminates the entire VM regardless of `stop_mode`.
Avoid those modes in embedded usage.

Cleanup of external workers runs whenever `cleanup_timeout` is greater than zero (default),
even if Snakepit is already started. For embedded usage where you do not own the pool,
set `cleanup_timeout: 0` to skip cleanup.

Exit mode guidance:
- `:none` (default) - return to the caller; the script runner controls VM exit.
- `:auto` - safe default for scripts that may run under `--no-halt`.
- `:stop` - request a graceful VM shutdown with the script status code.
- `:halt` - immediate VM termination; use only with explicit operator intent.

Wrapper commands (like `timeout`, `head`, or `tee`) can close stdout/stderr early and
trigger broken pipes during shutdown. Avoid writing to stdout in exit paths, and note
that GNU `timeout` is not available by default on macOS (use `gtimeout` from coreutils
or another portable watchdog).

### Script Lifecycle Reference

For the authoritative exit precedence, status code rules, `stop_mode x exit_mode` matrix,
shutdown state machine, and telemetry contract, see
`docs/20251229/documentation-overhaul/01-core-api.md#script-lifecycle-090`.

## Mix Tasks

| Task | Description |
|------|-------------|
| `mix snakepit.setup` | Install Python dependencies and generate gRPC stubs |
| `mix snakepit.doctor` | Verify environment is correctly configured |
| `mix snakepit.status` | Show pool status and worker information |
| `mix snakepit.gen.adapter NAME` | Generate adapter scaffolding |

## Examples

The `examples/` directory contains working demonstrations:

| Example | Description |
|---------|-------------|
| `grpc_basic.exs` | Basic execute, ping, echo, add operations |
| `grpc_sessions.exs` | Session affinity and isolation |
| `grpc_streaming.exs` | Pool scaling and concurrent execution |
| `hardware_detection.exs` | Hardware detection for ML workloads |
| `crash_recovery.exs` | Circuit breaker, retry, health monitoring |
| `bidirectional_tools_demo.exs` | Cross-language tool calls |
| `telemetry_basic.exs` | Telemetry event handling |
| `threaded_profile_demo.exs` | Python 3.13+ thread profile |

Run examples:

```bash
mix run examples/grpc_basic.exs
mix run examples/hardware_detection.exs
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](guides/getting-started.md) | Installation and first steps |
| [Configuration](guides/configuration.md) | All configuration options |
| [Worker Profiles](guides/worker-profiles.md) | Process vs thread profiles |
| [Hardware Detection](guides/hardware-detection.md) | ML accelerator detection |
| [Fault Tolerance](guides/fault-tolerance.md) | Circuit breaker, retry, health |
| [Streaming](guides/streaming.md) | gRPC streaming operations |
| [Graceful Serialization](guides/graceful-serialization.md) | Handling non-JSON-serializable objects |
| [Python Adapters](guides/python-adapters.md) | Writing Python adapters |
| [Observability](guides/observability.md) | Telemetry and logging |
| [Production](guides/production.md) | Deployment and troubleshooting |

## Requirements

- Elixir 1.18+
- Erlang/OTP 27+
- Python 3.9+ (3.13+ for thread profile)
- [uv](https://docs.astral.sh/uv/) - Fast Python package manager (required)
- gRPC Python packages (`grpcio`, `grpcio-tools`)

### Installing uv

```bash
# macOS/Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Windows
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

# Or via Homebrew
brew install uv
```

## License

MIT License - see [LICENSE](LICENSE) for details.
