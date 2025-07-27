# Snakepit Examples - Three Layer Architecture

This directory contains examples demonstrating Snakepit as a pure infrastructure layer in the three-layer architecture.

## New Examples (Aligned with Architecture)

### Core Snakepit Examples (No External Dependencies)

#### 01_basic_adapter.exs
Demonstrates the minimal Snakepit adapter contract:
- Required `execute/3` callback only
- No external processes or dependencies
- Shows pooling benefits even with simple adapters

```bash
elixir examples/01_basic_adapter.exs
```

#### 02_full_adapter.exs
Shows all adapter callbacks including optional ones:
- Lifecycle management (`init/1`, `terminate/2`)
- Custom worker processes (`start_worker/2`)
- Streaming support
- Cognitive metadata for future optimization

```bash
elixir examples/02_full_adapter.exs
```

#### 03_session_affinity.exs
Demonstrates session-based request routing:
- Stateful operations with worker affinity
- Session continuity across requests
- Load distribution across workers

```bash
elixir examples/03_session_affinity.exs
```

#### 04_bridge_integration.exs
Shows how the bridge layer integrates with Snakepit:
- Mock implementation of `SnakepitGRPCBridge.Adapter`
- Demonstrates separation of concerns
- Shows bridge features (variables, tools, ML ops)

```bash
elixir examples/04_bridge_integration.exs
```

## Migration Guide

The old examples use `Snakepit.Adapters.GRPCPython` which doesn't exist in the new architecture. Here's how they map:

| Old Example | New Approach |
|-------------|--------------|
| `grpc_basic.exs` | Use `SnakepitGRPCBridge.Adapter` from bridge layer |
| `grpc_sessions.exs` | Sessions handled by Snakepit, state by bridge |
| `grpc_streaming.exs` | Streaming is adapter-specific feature |
| `grpc_variables.exs` | Variables now in `SnakepitGRPCBridge.API.Variables` |
| `bidirectional_tools_demo.exs` | Tools in `SnakepitGRPCBridge.API.Tools` |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    DSPex (Layer 3)                      │
│                 Thin Orchestration Layer                │
│          Uses: SnakepitGRPCBridge.API.*                │
└────────────────────────┬───────────────────────────────┘
                         │
┌────────────────────────┴───────────────────────────────┐
│            SnakepitGRPCBridge (Layer 2)                │
│                  ML Platform Layer                      │
│   • All Python code       • Variables system           │
│   • gRPC communication    • Tools bridge               │
│   • DSPy integration      • Session state              │
│                                                         │
│   Implements: Snakepit.Adapter behavior                │
└────────────────────────┬───────────────────────────────┘
                         │
┌────────────────────────┴───────────────────────────────┐
│                 Snakepit (Layer 1)                      │
│              Pure Infrastructure Layer                  │
│   • Process pooling       • Worker lifecycle           │
│   • Session routing       • Adapter interface          │
│   • No ML knowledge       • No Python/gRPC            │
└─────────────────────────────────────────────────────────┘
```

## Running with the Bridge

To run examples with the actual bridge (Python/gRPC):

1. Configure the bridge adapter:
```elixir
Application.put_env(:snakepit, :adapter_module, SnakepitGRPCBridge.Adapter)
```

2. Ensure Python dependencies are installed:
```bash
cd ../snakepit_grpc_bridge/priv/python
pip install -r requirements.txt
```

3. The bridge will automatically:
   - Start Python processes
   - Manage gRPC connections
   - Handle ML operations

## Key Concepts

### Adapter Contract
The `Snakepit.Adapter` behavior is the ONLY coupling between layers:
- Required: `execute(command, args, opts)`
- Optional: lifecycle, streaming, cognitive features

### Process Management
Snakepit provides robust process management:
- Automatic restart on crash
- Orphan prevention via BEAM run ID
- Graceful shutdown with cleanup

### Session Affinity
Built-in session routing for stateful operations:
- Same session → same worker
- Enables caching and state
- Transparent to adapters

## Testing Adapters

Create test modules that implement the adapter behavior:

```elixir
defmodule MyAdapter do
  @behaviour Snakepit.Adapter
  
  def execute("ping", _args, _opts), do: {:ok, "pong"}
  def execute(cmd, args, _opts), do: {:ok, %{cmd: cmd, args: args}}
end

# Validate implementation
Snakepit.Adapter.validate_implementation(MyAdapter)
```

## Best Practices

1. **Keep Snakepit Pure**: No domain logic in infrastructure
2. **Leverage the Contract**: Use optional callbacks for advanced features
3. **Test with Mocks**: Use mock adapters before integrating real ones
4. **Session Wisely**: Use sessions for stateful operations only
5. **Monitor Performance**: Use cognitive metadata for optimization