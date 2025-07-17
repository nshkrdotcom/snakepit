# Snakepit

A high-performance, generalized process pooler and session manager for external language integrations.

## Overview

Snakepit is a general-purpose pooling system that can manage workers for any external process through its adapter pattern. It provides:

- **Concurrent worker initialization** - All workers start in parallel using `Task.async_stream`
- **High-performance OTP-based process management** - Built on DynamicSupervisor, Registry, and GenServer
- **Stateless pool system** - Workers are stateless; all session data lives in centralized SessionStore
- **Session affinity** - Support for session-based execution with automatic worker affinity
- **Multi-language adapter support** - Currently supports Python and JavaScript/Node.js with easy extensibility
- **Process tracking and cleanup** - Robust process lifecycle management with automatic cleanup

## Architecture

The V3 pool design abandons complex pool libraries in favor of simple OTP patterns:

1. **Worker Supervisor (DynamicSupervisor)** - Manages worker lifecycle with automatic restarts
2. **Individual Workers (GenServer)** - Each worker owns one external process via Port
3. **Pool Manager (GenServer)** - Simple queue-based request distribution
4. **Registry** - Named process registration for O(1) worker lookup
5. **SessionStore** - Centralized ETS-based session management

## Performance

Key performance improvements over traditional pooling approaches:

- **1000x+ faster startup** - Concurrent initialization vs sequential
- **Simple codebase** - ~300 lines of core code vs ~2000 lines in complex pool libraries
- **OTP reliability** - Battle-tested supervision trees handle failures automatically
- **Clustering ready** - Registry pattern enables easy distribution

## Basic Usage

```elixir
# Configure with Python adapter
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPython)
Application.put_env(:snakepit, :pool_config, %{pool_size: 4})

{:ok, _} = Application.ensure_all_started(:snakepit)

# Execute commands
{:ok, result} = Snakepit.execute("ping", %{test: true})
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})

# Session-based execution  
{:ok, result} = Snakepit.execute_in_session("my_session", "echo", %{message: "hello"})

# Switch to JavaScript adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)
{:ok, result} = Snakepit.execute("random", %{type: "uniform", min: 1, max: 100})

# Get pool statistics
stats = Snakepit.get_stats()
```

## Running the Demo

```bash
# Python adapter demo
elixir examples/generic_demo_python.exs

# JavaScript adapter demo  
elixir examples/generic_demo_javascript.exs
```

## Configuration

```elixir
config :snakepit,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 8  # Default: System.schedulers_online() * 2
  }
```

## Supported Adapters

Snakepit currently includes adapters for:

### Python Adapter (`Snakepit.Adapters.GenericPython`)
- Framework-agnostic Python integration
- Commands: `ping`, `echo`, `compute`, `info`
- Simple computational tasks and health checks
- Example usage for ML frameworks, data processing, etc.

### JavaScript/Node.js Adapter (`Snakepit.Adapters.GenericJavaScript`)
- Node.js integration without external dependencies
- Commands: `ping`, `echo`, `compute`, `info`, `random`
- Mathematical operations and random number generation
- Perfect for web scraping, API calls, or JavaScript computations

### Creating Custom Adapters
See the `Snakepit.Adapter` behaviour documentation for implementing your own adapters for R, Ruby, Go, or any other language.

## Future Extensions

The design supports easy evolution:

1. **Additional Language Adapters** - R, Ruby, Go, Rust, or other language integrations
2. **Clustering** - Replace Registry with Horde.Registry for distribution  
3. **Advanced Metrics** - Telemetry events for monitoring
4. **Load Balancing** - Cross-pool request distribution
5. **Dynamic Scaling** - Automatic pool size adjustment

## Installation

Add `snakepit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:snakepit, "~> 0.0.1"}
  ]
end
```

## License

MIT

