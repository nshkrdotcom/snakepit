# Snakepit Showcase

A comprehensive example application demonstrating all features of Snakepit, the high-performance process pooler for external language integrations.

## Features Demonstrated

- ✅ Basic command execution and error handling
- ✅ Session management and stateful operations
- ✅ Streaming with real-time progress updates
- ✅ Concurrent processing and pool management
- ✅ Variable management with type validation
- ✅ **Binary serialization for large data (NEW)**
- ✅ Complete ML workflows with model training/inference

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
mix run -e "SnakepitShowcase.Demos.BinaryDemo.run()"
```

## Binary Serialization Demo

The showcase includes a comprehensive demonstration of Snakepit's automatic binary serialization:

### What It Shows

1. **Automatic Threshold Detection**
   - Small tensors (<10KB) use JSON
   - Large tensors (>10KB) use binary
   - Zero configuration required

2. **Performance Comparison**
   - Side-by-side benchmarks
   - 5-10x speedup for large data
   - Memory efficiency metrics

3. **Real-world Examples**
   - ML embeddings (128D to 2048D)
   - Image tensors
   - Training datasets

### Running the Binary Demo

```elixir
# From IEx
iex> SnakepitShowcase.Demos.BinaryDemo.run()

# Output shows:
# - Encoding type (JSON vs Binary)
# - Performance metrics
# - Size comparisons
# - Speedup calculations
```

Example output:
```
🔬 Binary Serialization Demo

1️⃣ Small Tensor (JSON Encoding)
   Created: small_tensor
   Shape: [10, 10]
   Size: 800 bytes
   Encoding: json
   Time: 5ms

2️⃣ Large Tensor (Binary Encoding)
   Created: large_tensor
   Shape: [100, 100]
   Size: 80000 bytes
   Encoding: binary
   Time: 8ms

3️⃣ Performance Comparison

   Shape      | Size       | JSON (ms) | Binary (ms) | Speedup
   -----------|------------|-----------|-------------|--------
   [10, 10]   | 100 elements (800B) |        12 |          15 | 0.8x
   [50, 50]   | 2,500 elements (20KB) |       45 |          18 | 2.5x
   [100, 100] | 10,000 elements (80KB) |      156 |          22 | 7.1x
   [200, 200] | 40,000 elements (320KB) |     642 |          38 | 16.9x
```

## Available Demos

### 1. Basic Operations (`BasicDemo`)
- Health checks and ping/pong
- Echo command with various data types
- Error handling demonstration
- Custom adapter information

### 2. Session Management (`SessionDemo`)
- Session creation and lifecycle
- Stateful counter operations
- Worker affinity verification
- Session cleanup with statistics

### 3. Streaming Operations (`StreamingDemo`)
- Progress updates with percentages
- Fibonacci sequence streaming
- Large dataset chunking
- Stream cancellation

### 4. Concurrent Processing (`ConcurrentDemo`)
- Parallel task execution
- Pool saturation handling
- Performance benchmarking
- Resource management

### 5. Variable Management (`VariablesDemo`)
- Type registration (float, integer, string, boolean, choice)
- Constraint validation
- Batch get/set operations
- Version history tracking

### 6. Binary Serialization (`BinaryDemo`)
- Automatic encoding detection
- Performance comparison
- Tensor and embedding handling
- Memory efficiency demonstration

### 7. ML Workflows (`MLWorkflowDemo`)
- Data loading and preprocessing
- Feature engineering
- Model training with progress
- Batch predictions with embeddings

## Project Structure

```
snakepit_showcase/
├── lib/
│   └── snakepit_showcase/
│       ├── application.ex          # OTP application
│       ├── demo_runner.ex          # Demo orchestration
│       └── demos/                  # Individual demo modules
│           ├── basic_demo.ex
│           ├── binary_demo.ex      # Binary serialization demo
│           ├── concurrent_demo.ex
│           ├── ml_workflow_demo.ex
│           ├── session_demo.ex
│           ├── streaming_demo.ex
│           └── variables_demo.ex
├── config/                         # Application configuration
├── mix.exs                        # Mix project file
└── README.md                      # This file
```

## Configuration

The showcase uses Snakepit as a path dependency:

```elixir
# mix.exs
{:snakepit, path: "../../"}
```

Snakepit is configured in `config/config.exs`:

```elixir
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 4,
    max_overflow: 2,
    strategy: :fifo,
    adapter_args: ["--adapter", "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"]
  },
  grpc_config: %{
    base_port: 50051,
    port_range: 100,
    health_check_interval: 30_000
  }
```

## Python Adapter

The showcase uses the built-in `ShowcaseAdapter` from Snakepit's Python bridge that demonstrates:

- All Snakepit features
- Binary serialization with numpy
- ML operations
- Streaming capabilities
- Session management
- Error handling

## Adding New Demos

1. Create a new module in `lib/snakepit_showcase/demos/`
2. Implement the `run/0` function
3. Add to the `@demos` list in `DemoRunner`
4. Optionally add Python methods to the adapter

Example:
```elixir
defmodule SnakepitShowcase.Demos.MyDemo do
  def run do
    IO.puts("🎯 My Demo")
    
    # Your demo code here
    {:ok, result} = Snakepit.execute("my_command", %{})
    
    IO.puts("Result: #{inspect(result)}")
    
    :ok
  end
end
```

## Troubleshooting

### Python Dependencies

The ShowcaseAdapter requires numpy for binary serialization demos. Snakepit automatically installs its dependencies when started.

### Pool Saturation

If demos timeout, check your pool configuration. The default is 4 workers:

```elixir
# Increase pool size in config/config.exs
pool_config: %{
  pool_size: 8,  # Increase this
  max_overflow: 2,
  # ...
}
```

### Binary Serialization Not Working

Ensure you have the latest Snakepit with binary support:

```bash
cd ../..  # Back to snakepit root
mix test  # Run tests to verify
```

## Learn More

- Main Snakepit documentation: `../../README.md`
- Binary serialization guide: `../../priv/python/BINARY_SERIALIZATION.md`
- Architecture overview: `../../ARCHITECTURE.md`
- Protocol documentation: `../../priv/proto/README.md`

## Contributing

This showcase is designed to be extended. Feel free to add new demos that demonstrate additional Snakepit features or use cases!