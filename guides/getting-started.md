# Getting Started with Snakepit

This guide walks you through installing Snakepit and running your first Python command from Elixir. By the end, you will have a working pool of Python workers executing commands via gRPC.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Creating a Python Adapter](#creating-a-python-adapter)
5. [Running Your First Command](#running-your-first-command)
6. [Next Steps](#next-steps)

---

## Prerequisites

### Elixir and Erlang

Snakepit requires Elixir 1.18+ and Erlang/OTP 27+:

```bash
elixir --version
# Elixir 1.18.4 (compiled with Erlang/OTP 27)
```

If you need to install or upgrade, see [elixir-lang.org/install](https://elixir-lang.org/install.html) or use a version manager like `asdf`.

### Python

Python 3.9 or later is required. Python 3.13+ is recommended for the thread worker profile:

```bash
python3 --version
# Python 3.12.4
```

### Python Packages

The Python bridge requires gRPC and related packages. These are installed automatically by `mix snakepit.setup`, but for reference:

| Package | Minimum Version | Purpose |
|---------|-----------------|---------|
| `grpcio` | 1.60.0 | gRPC runtime |
| `grpcio-tools` | 1.60.0 | Protocol buffer compiler |
| `protobuf` | 4.25.0 | Protocol buffer runtime |
| `numpy` | 1.21.0 | Array operations |
| `psutil` | 5.9.0 | Process monitoring |

---

## Installation

### Step 1: Add Snakepit to Your Project

Add Snakepit as a dependency in your `mix.exs`:

```elixir
# mix.exs
def deps do
  [
    {:snakepit, "~> 0.12.0"}
  ]
end
```

Then fetch and compile:

```bash
mix deps.get
mix compile
```

### Step 2: Set Up the Python Environment

Snakepit provides Mix tasks to bootstrap the Python environment:

```bash
# Create virtual environments and install dependencies
mix snakepit.setup

# Verify everything is configured correctly
mix snakepit.doctor
```

The setup task creates `.venv` (Python 3.12) and optionally `.venv-py313` (Python 3.13 with free-threading). The doctor task checks:

- Python executable availability
- gRPC module imports
- Adapter health checks
- Port availability for the Elixir gRPC server

### Step 3: Configure Snakepit

Add basic configuration to `config/config.exs`:

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pool_size: 4
```

For production, increase `pool_size` based on your workload (typically `System.schedulers_online() * 2`).

---

## Quick Start

Here is the minimal code to execute a Python command from Elixir:

```elixir
# Ensure Snakepit is started
{:ok, _} = Application.ensure_all_started(:snakepit)

# Wait for the pool to initialize
:ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

# Execute a command on any available worker
{:ok, result} = Snakepit.execute("ping", %{message: "hello"})
IO.inspect(result)
# => %{"status" => "ok", "message" => "pong", "timestamp" => 1704067200.123}
```

The `execute/3` function sends the command to a Python worker, which processes it and returns the result.

### Understanding the Flow

1. **Pool Initialization**: Snakepit starts Python processes (workers) based on `pool_size`
2. **Worker Ready**: Each worker connects via gRPC and reports readiness
3. **Execute Command**: Your command is routed to an available worker
4. **Process and Return**: The Python adapter processes the command and returns results

---

## Creating a Python Adapter

Adapters define what commands your Python workers can handle. Here is a simple adapter:

```python
# my_adapter.py
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    """A simple adapter with basic tools."""

    def __init__(self):
        super().__init__()

    @tool(description="Echo a message back")
    def echo(self, message: str) -> dict:
        """Return the message with a timestamp."""
        import time
        return {
            "message": message,
            "timestamp": time.time(),
            "success": True
        }

    @tool(description="Add two numbers")
    def add(self, a: float, b: float) -> dict:
        """Add two numbers and return the result."""
        return {
            "result": a + b,
            "operation": "addition",
            "success": True
        }

    @tool(description="Process a list of items")
    def process_list(self, items: list, operation: str = "count") -> dict:
        """Process a list with the specified operation."""
        operations = {
            "count": len,
            "sum": sum,
            "max": max,
            "min": min
        }

        if operation not in operations:
            return {
                "error": f"Unknown operation: {operation}",
                "available": list(operations.keys()),
                "success": False
            }

        return {
            "result": operations[operation](items),
            "operation": operation,
            "success": True
        }
```

### Key Concepts

- **BaseAdapter**: Inherit from this class for tool discovery and registration
- **@tool decorator**: Marks methods as callable tools with metadata
- **Type hints**: Parameters are automatically documented in tool specifications
- **Return dictionaries**: Results are serialized to JSON and returned to Elixir

### Registering Your Adapter

Configure Snakepit to use your adapter:

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "my_adapter.MyAdapter"]
```

Ensure your adapter module is in the Python path:

```bash
export PYTHONPATH="$PYTHONPATH:/path/to/your/adapters"
```

---

## Running Your First Command

### Basic Execution

Call tools defined in your adapter:

```elixir
# Echo a message
{:ok, result} = Snakepit.execute("echo", %{message: "Hello from Elixir!"})
# => {:ok, %{"message" => "Hello from Elixir!", "timestamp" => 1704067200.5, "success" => true}}

# Add two numbers
{:ok, result} = Snakepit.execute("add", %{a: 10, b: 25})
# => {:ok, %{"result" => 35, "operation" => "addition", "success" => true}}

# Process a list
{:ok, result} = Snakepit.execute("process_list", %{items: [1, 2, 3, 4, 5], operation: "sum"})
# => {:ok, %{"result" => 15, "operation" => "sum", "success" => true}}
```

### With Timeout

Specify a timeout for long-running operations:

```elixir
{:ok, result} = Snakepit.execute("long_task", %{data: large_payload}, timeout: 120_000)
```

### Error Handling

Handle execution errors gracefully:

```elixir
case Snakepit.execute("unknown_command", %{}) do
  {:ok, result} ->
    IO.puts("Success: #{inspect(result)}")

  {:error, %Snakepit.Error{category: :worker_error, message: message}} ->
    IO.puts("Worker error: #{message}")

  {:error, %Snakepit.Error{category: :timeout}} ->
    IO.puts("Request timed out")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end
```

### Script Mode

For scripts and Mix tasks, use `run_as_script/2` to ensure proper cleanup and explicit exit behavior:

```elixir
# my_script.exs
Snakepit.run_as_script(fn ->
  {:ok, result} = Snakepit.execute("process_data", %{input: data})
  IO.puts("Result: #{inspect(result)}")
end, timeout: 30_000, exit_mode: :auto)
```

Defaults are `exit_mode: :none` and `stop_mode: :if_started`. For embedded usage, keep
`exit_mode: :none` and set `stop_mode: :never` to avoid shutting down the host VM.

You can also set `SNAKEPIT_SCRIPT_EXIT` to `none|halt|stop|auto` when options are not
explicitly provided. `SNAKEPIT_SCRIPT_HALT` is deprecated in favor of `SNAKEPIT_SCRIPT_EXIT`.

Cleanup runs whenever `cleanup_timeout` is greater than zero (default), even if Snakepit
is already started. For embedded usage where you do not own the pool, set
`cleanup_timeout: 0` to skip cleanup.

See `docs/20251229/documentation-overhaul/01-core-api.md#script-lifecycle-090` for the
authoritative exit precedence and shutdown tables.

---

## Next Steps

Now that you have Snakepit running, explore these topics:

### Configuration

Learn about all configuration options including multi-pool setups:

- [Configuration Guide](configuration.md) - Pool options, logging, Python runtime settings

### Worker Profiles

Understand the different worker execution models:

- [Worker Profiles Guide](worker-profiles.md) - Process vs Thread profiles, when to use each

### Advanced Features

Explore more capabilities:

- [Streaming](streaming.md) - Stream large results incrementally
- [Python Adapters](python-adapters.md) - Session context and bidirectional tools
- [Observability](observability.md) - Monitor pool health and performance
- [Fault Tolerance](fault-tolerance.md) - Error handling and recovery patterns

### Thread-Safe Adapters

For CPU-bound workloads with Python 3.13+:

- [Python Threading Guide](../priv/python/README_THREADING.md) - Concurrency patterns

---

## Troubleshooting

### Workers Not Starting

```bash
# Check Python setup
mix snakepit.doctor

# View detailed logs
config :snakepit, log_level: :debug
```

### Import Errors

Ensure your adapter is in the Python path:

```bash
# Check if Python can import your adapter
python3 -c "from my_adapter import MyAdapter; print('OK')"
```

### Port Conflicts

Internal-only mode uses an ephemeral port, so conflicts only apply when
you explicitly bind a fixed port. If port 50051 is in use:

```elixir
config :snakepit,
  grpc_listener: %{
    mode: :external,
    host: "localhost",
    port: 60051
  }
```

### ETS Table Errors

If you see errors about missing ETS tables (`:snakepit_worker_taints` or
`:snakepit_zero_copy_handles`), ensure the Snakepit application is started:

```elixir
# Correct: Start the application first
{:ok, _} = Application.ensure_all_started(:snakepit)

# Then use Snakepit functions
{:ok, result} = Snakepit.execute("ping", %{})
```

The `Snakepit.ETSOwner` GenServer owns these tables and must be running before
any taint registry or zero-copy operations. This happens automatically when
Snakepit starts.

See [Production Guide](production.md) for comprehensive troubleshooting.
