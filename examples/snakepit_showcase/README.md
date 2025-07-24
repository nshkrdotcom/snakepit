# Snakepit Showcase

A comprehensive example application demonstrating all features and best practices of Snakepit, the high-performance process pooler for external language integrations.

## 🚀 Features Demonstrated

- ✅ Basic command execution and error handling
- ✅ Session management with proper state handling in Elixir
- ✅ Streaming with real-time progress updates
- ✅ Concurrent processing with robust error recovery
- ✅ Variable management with type validation
- ✅ Binary serialization for large data
- ✅ Complete ML workflows with model training/inference
- ✅ **Enhanced tool capabilities (v0.4.1)**:
  - `process_text` - Text processing with upper, lower, reverse, length operations
  - `get_stats` - Real-time adapter and system monitoring
- ✅ **Execution modes guide** - When to use each pattern

## 🏗️ Architecture Improvements

This showcase demonstrates production-ready patterns:

### 1. State Management
- All state is managed through Elixir's SessionStore via SessionContext
- Python workers remain stateless for better scalability
- No memory leaks or state accumulation in workers

### 2. Code Organization
- Modular handler architecture for better maintainability
- Domain-specific handlers (ML, streaming, binary, etc.)
- Clean separation of concerns

### 3. Error Handling
- Comprehensive error recovery patterns
- Graceful degradation strategies
- Informative error messages with troubleshooting tips

### 4. Execution Patterns
- Clear guidance on when to use stateless vs session-based execution
- Performance trade-offs documented
- Real-world usage examples

## Quick Start

```bash
# From the snakepit_showcase directory
cd examples/snakepit_showcase

# Install dependencies
mix setup

# Run all demos
mix demo.all

# Interactive mode
mix demo.interactive

# Run specific demo
mix demo.execution_modes
```

## Important: Process Management

All demos use `Snakepit.run_as_script/2` to ensure:
- Deterministic pool initialization (no race conditions)
- Proper cleanup of all Python processes on exit
- No orphaned processes after demo completion

This is handled automatically by the framework - you don't need to add any cleanup code!

## Demos Overview

### 1. Basic Operations
Demonstrates fundamental Snakepit operations with proper error handling.

### 2. Session Management
Shows how to properly manage state through SessionContext, avoiding Python-side state accumulation.

### 3. Streaming Operations
Real-time progress updates and efficient handling of large datasets.

### 4. Concurrent Processing
Robust patterns for parallel execution with failure recovery and retry logic.

### 5. Variable Management
Type-safe variable operations with automatic serialization.

### 6. Binary Serialization
Automatic optimization for large tensors and embeddings with 5-10x performance gains.

### 7. ML Workflows
Complete machine learning pipeline with error handling, timeouts, and progress tracking.

### 8. Execution Modes Guide
Interactive demonstration of when to use different execution patterns:
- Stateless execution for maximum parallelism
- Session-based for stateful workflows
- Streaming for long operations

## Best Practices Demonstrated

### State Management
```python
# ❌ BAD: State in Python class
class BadAdapter:
    counters = {}  # This accumulates forever!
    
# ✅ GOOD: State in SessionContext
def increment_counter(self, ctx):
    current = ctx.get_variable('counter', 0)
    ctx['counter'] = current + 1
```

### Error Handling
```elixir
# ❌ BAD: Crashes on error
{:ok, result} = Snakepit.execute("risky_operation", %{})

# ✅ GOOD: Graceful handling
case Snakepit.execute("risky_operation", %{}) do
  {:ok, result} -> process_result(result)
  {:error, %{error_type: "SpecificError"}} -> handle_specific_error()
  {:error, reason} -> handle_generic_error(reason)
end
```

### Choosing Execution Mode
```elixir
# Stateless - for independent operations
results = Task.async_stream(items, fn item ->
  Snakepit.execute("process_item", %{data: item})
end)

# Session-based - for stateful workflows
{:ok, session_id} = create_session()
Snakepit.execute_in_session(session_id, "load_model", %{})
Snakepit.execute_in_session(session_id, "predict", %{data: input})
```

## Configuration

The showcase uses optimized settings in `config/config.exs`:

```elixir
config :snakepit,
  pool_config: %{
    adapter: Snakepit.Adapters.GRPCPython,
    pool_size: 4,
    pool_strategy: :fifo,
    adapter_args: [
      python_module: "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"
    ]
  }
```

## Python Requirements

```bash
pip install -r requirements.txt
```

Required packages:
- numpy
- psutil
- grpcio
- protobuf

## Troubleshooting

### Common Issues

1. **Import errors**: Ensure Python path includes the project root
2. **gRPC errors**: Check that ports 50051-50151 are available
3. **State not persisting**: Verify you're using SessionContext, not local variables
4. **High memory usage**: Check for state accumulation in Python workers

### Debug Mode

Enable debug logging:
```elixir
config :logger, level: :debug
```

## Learn More

- [Snakepit Documentation](../../README.md)
- [gRPC Bridge Design](../../README_GRPC_BRIDGE.md)
- [Technical Specification](docs/showcase-improvements-technical-spec.md)

## License

This showcase is part of the Snakepit project and follows the same license terms.