# Snakepit

<div align="center">
  <img src="assets/snakepit-logo.svg" alt="Snakepit Logo" width="200" height="200">
</div>

> A high-performance, generalized process pooler and session manager for external language integrations in Elixir

[![Hex Version](https://img.shields.io/hexpm/v/snakepit.svg)](https://hex.pm/packages/snakepit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/snakepit)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/Elixir-1.18%2B-purple.svg)](https://elixir-lang.org)

## Overview

Snakepit is an Elixir library for managing pools of external language workers (Python, Node.js, Ruby, etc.) via gRPC. It provides:

- **High-performance process pooling** with concurrent worker initialization
- **Session affinity** for stateful operations across requests
- **gRPC streaming** for real-time progress updates and large data transfers
- **Bidirectional tool bridge** allowing Python to call Elixir functions and vice versa
- **Production-ready process management** with automatic orphan cleanup
- **Comprehensive telemetry** with OpenTelemetry support
- **Zero-copy data interop** via DLPack and Arrow (optional)
- **Crash barrier** with tainting and idempotent retries (optional)
- **Hermetic Python runtime** via uv-managed installs (optional)
- **Python package management** with uv/pip installers (optional)
- **Structured exception translation** for Python errors (pattern-matchable)

## Installation

Add `snakepit` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:snakepit, "~> 0.7.5"}
  ]
end
```

Then run:

```bash
mix deps.get
mix snakepit.setup    # Install Python dependencies and generate gRPC stubs
mix snakepit.doctor   # Verify environment is correctly configured
```

## Quick Start

### Configuration

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "your_adapter_module"],
  pool_size: 10,
  zero_copy: [enabled: true],
  crash_barrier: [enabled: true, max_retries: 1, taint_ms: 5_000],
  python: [strategy: :uv, managed: true, python_version: "3.12.3"]
```

### Basic Usage

```elixir
# Execute a command on any available worker
{:ok, result} = Snakepit.execute("your_command", %{param: "value"})

# Execute with session affinity (same worker for related requests)
{:ok, result} = Snakepit.execute_in_session("session_123", "command", %{})

# Stream results for long-running operations
Snakepit.execute_stream("batch_process", %{items: items}, fn chunk ->
  IO.puts("Progress: #{chunk.progress}%")
end)
```

### Script Mode

For scripts and Mix tasks, use `run_as_script/2` for automatic lifecycle management:

```elixir
Snakepit.run_as_script(fn ->
  {:ok, result} = Snakepit.execute("process_data", %{})
  IO.inspect(result)
end)
```

## Architecture

Snakepit uses a layered OTP supervision tree:

```
Snakepit.Supervisor
├── SessionStore          # ETS-backed session management
├── ToolRegistry          # Bidirectional tool registration
├── GRPC.Server           # Receives calls from Python workers
├── Pool                  # Request distribution and worker tracking
│   └── WorkerSupervisor
│       └── Worker.Starter (per worker)
│           └── GRPCWorker # Manages individual Python process
└── ApplicationCleanup    # Graceful shutdown guarantees
```

Each `GRPCWorker` spawns and manages a Python process via OS ports, communicating over gRPC for both request/response and streaming operations.

## Worker Profiles

Snakepit supports two worker isolation strategies:

### Process Profile (Default)
- One Python process per worker
- Full process isolation (crashes don't affect other workers)
- Works with all Python versions
- Best for I/O-bound workloads

### Thread Profile (Python 3.13+)
- Multiple threads within each Python process
- Shared memory for zero-copy data sharing
- True parallelism with free-threaded Python
- Best for CPU-bound workloads with large shared data

```elixir
config :snakepit,
  pools: [
    %{name: :default, worker_profile: :process, pool_size: 10},
    %{name: :compute, worker_profile: :thread, pool_size: 4, threads_per_worker: 8}
  ]
```

## Writing Python Adapters

Create a Python adapter by extending `BaseAdapter`:

```python
# priv/python/my_adapter.py
from snakepit_bridge import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    @tool
    def process_data(self, params):
        """Process data and return result."""
        return {"result": params["input"] * 2}

    @tool(supports_streaming=True)
    def batch_process(self, params, stream):
        """Stream progress updates during processing."""
        items = params["items"]
        for i, item in enumerate(items):
            result = self._process_item(item)
            stream.send({"progress": (i + 1) / len(items) * 100, "item": result})
        return {"total": len(items)}
```

Generate adapter scaffolding:

```bash
mix snakepit.gen.adapter MyAdapter
```

## Features

### Session Management
Sessions provide worker affinity and state isolation:

```elixir
# Create session with automatic worker affinity
{:ok, result1} = Snakepit.execute_in_session("user_123", "load_model", %{})
{:ok, result2} = Snakepit.execute_in_session("user_123", "predict", %{})
# Both calls go to the same worker when possible
```

### Bidirectional Tool Bridge
Python can call registered Elixir functions:

```elixir
# Register Elixir tool
Snakepit.Bridge.ToolRegistry.register_elixir_tool(
  "calculate",
  fn params -> {:ok, params["a"] + params["b"]} end,
  %{description: "Add two numbers"}
)
```

```python
# Call from Python
result = session_context.call_elixir_tool("calculate", {"a": 1, "b": 2})
```

### Telemetry & Observability
Comprehensive event emission for monitoring:

```elixir
:telemetry.attach("my-handler", [:snakepit, :pool, :worker, :spawned], fn event, measurements, metadata, _ ->
  Logger.info("Worker spawned in #{measurements.duration}ms")
end, nil)
```

OpenTelemetry integration for distributed tracing:

```elixir
config :snakepit, :opentelemetry, %{enabled: true}
```

### Zero-Copy Interop
Use `Snakepit.ZeroCopy` for DLPack/Arrow handle lifecycle:

```elixir
{:ok, dlpack} = Snakepit.ZeroCopy.to_dlpack(tensor)
{:ok, tensor} = Snakepit.ZeroCopy.from_dlpack(dlpack)
:ok = Snakepit.ZeroCopy.close(dlpack)
```

### Crash Barrier & Idempotent Retries
Crash barrier classifies worker crashes, taints unstable workers, and retries
idempotent calls when allowed:

```elixir
config :snakepit, :crash_barrier,
  enabled: true,
  retry: :idempotent,
  max_retries: 1,
  taint_ms: 5_000

case Snakepit.execute("load_model", %{idempotent: true, model_id: "v1"}) do
  {:ok, result} -> result
  {:error, error} -> raise "Call failed: #{Exception.message(error)}"
end
```

### Hermetic Python Runtime
Use uv-managed installs for deterministic Python runtimes:

```elixir
config :snakepit, :python,
  strategy: :uv,
  managed: true,
  python_version: "3.12.3",
  runtime_dir: "priv/snakepit/python"

mix snakepit.setup
mix snakepit.doctor
```

### Python Package Management
Provision packages into the resolved Python runtime:

```elixir
Snakepit.PythonPackages.ensure!({:list, ["numpy~=1.26", "scipy~=1.11"]})

case Snakepit.PythonPackages.check_installed(["numpy~=1.26"]) do
  {:ok, :all_installed} -> :ok
  {:ok, {:missing, packages}} -> IO.inspect(packages, label: "Missing")
end
```

Configure the installer and environment:

```elixir
config :snakepit, :python_packages,
  installer: :auto,
  timeout: 300_000,
  env: %{
    "PYTHONNOUSERSITE" => "1",
    "PIP_DISABLE_PIP_VERSION_CHECK" => "1",
    "PIP_NO_INPUT" => "1"
  }
```

### Exception Translation
Python exceptions map to pattern-matchable Elixir structs:

```elixir
case Snakepit.execute("error_demo", %{error_type: "value"}) do
  {:error, %Snakepit.Error.ValueError{message: message}} ->
    IO.puts("ValueError: #{message}")

  {:error, %Snakepit.Error.PythonException{python_type: type}} ->
    IO.puts("Unhandled Python error: #{type}")
end
```

### Process Management
Automatic cleanup prevents orphaned Python processes:

- Tracks all spawned processes with unique run IDs
- Cleans up orphans on application restart
- Graceful shutdown with SIGTERM followed by SIGKILL if needed

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](ARCHITECTURE.md) | System design and component overview |
| [Diagrams](DIAGRAMS.md) | Visual architecture diagrams |
| [gRPC Streaming](README_GRPC.md) | Real-time streaming operations |
| [Tool Bridge](README_BIDIRECTIONAL_TOOL_BRIDGE.md) | Cross-language function calls |
| [Process Management](README_PROCESS_MANAGEMENT.md) | Worker lifecycle and cleanup |
| [Testing](README_TESTING.md) | Test organization and execution |
| [Telemetry](TELEMETRY.md) | Observability and metrics |
| [Log Configuration](LOG_LEVEL_CONFIGURATION.md) | Logging control |

## Requirements

- Elixir 1.18+
- Erlang/OTP 27+
- Python 3.9+ (3.13+ for thread profile)
- gRPC Python packages (`grpcio`, `grpcio-tools`)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

See [CHANGELOG.md](CHANGELOG.md) for version history. Development guidelines are in `AGENTS.md`.
