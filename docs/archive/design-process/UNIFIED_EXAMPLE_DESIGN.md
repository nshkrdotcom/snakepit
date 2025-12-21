# Unified Example Application Design Document

## Overview

This document describes the design for `snakepit_showcase` - a comprehensive example application that demonstrates all features of Snakepit in a single, cohesive Elixir application. This will replace the current collection of ad-hoc example scripts with a fully-featured application that developers can use as a reference implementation.

## Project Structure

```
examples/snakepit_showcase/
├── .formatter.exs
├── .gitignore
├── README.md
├── mix.exs
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
├── lib/
│   ├── snakepit_showcase.ex
│   ├── snakepit_showcase/
│   │   ├── application.ex
│   │   ├── demo_runner.ex
│   │   ├── demos/
│   │   │   ├── basic_demo.ex
│   │   │   ├── session_demo.ex
│   │   │   ├── streaming_demo.ex
│   │   │   ├── concurrent_demo.ex
│   │   │   ├── variables_demo.ex
│   │   │   ├── binary_demo.ex
│   │   │   └── ml_workflow_demo.ex
│   │   ├── python_adapters/
│   │   │   ├── showcase_adapter.py
│   │   │   ├── ml_adapter.py
│   │   │   ├── streaming_adapter.py
│   │   │   └── dspy_adapter.py
│   │   └── web/
│   │       ├── router.ex
│   │       ├── endpoint.ex
│   │       └── live/
│   │           ├── dashboard_live.ex
│   │           └── demo_live.ex
├── priv/
│   ├── static/
│   └── python/
│       └── requirements.txt
└── test/
    ├── test_helper.exs
    └── snakepit_showcase_test.exs
```

## Core Features to Demonstrate

### 1. Basic Operations (from grpc_basic.exs)
- Simple command execution
- Error handling
- Health checks
- Custom adapter usage

### 2. Session Management (from grpc_sessions.exs)
- Session creation and lifecycle
- Session affinity
- Stateful operations
- Session cleanup

### 3. Streaming Operations (from grpc_streaming.exs)
- Real-time progress updates
- Chunked data processing
- Stream cancellation
- Error handling in streams

### 4. Concurrent Processing (from grpc_concurrent.exs)
- Parallel task execution
- Pool saturation handling
- Performance benchmarking
- Resource management

### 5. Variable Management (from grpc_variables.exs)
- Variable registration with types
- Get/Set operations
- Batch operations
- Type validation and constraints

### 6. Binary Serialization (NEW)
- Large tensor handling
- Embedding processing
- Performance comparison (JSON vs Binary)
- Memory efficiency demonstration

### 7. Advanced ML Workflows (from grpc_advanced.exs)
- DSPy integration
- Multi-step pipelines
- Model training and inference
- Real-world ML use cases

## Implementation Plan

### Phase 1: Project Setup

```elixir
# mix.exs
defmodule SnakepitShowcase.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit_showcase,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SnakepitShowcase.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Use Snakepit from parent directory
      {:snakepit, path: "../../"},
      
      # Web interface (optional but recommended)
      {:phoenix, "~> 1.7.0"},
      {:phoenix_live_view, "~> 0.20.0"},
      {:phoenix_live_dashboard, "~> 0.8.0"},
      
      # Development tools
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      
      # Testing
      {:ex_unit_notifier, "~> 1.3", only: :test},
      {:mock, "~> 0.3.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --cd priv/python pip install -r requirements.txt"],
      "python.setup": ["cmd --cd priv/python pip install -r requirements.txt"],
      demo: ["run --no-halt"],
      "demo.all": ["run --no-halt -e SnakepitShowcase.DemoRunner.run_all()"],
      "demo.interactive": ["run --no-halt -e SnakepitShowcase.DemoRunner.interactive()"]
    ]
  end
end
```

### Phase 2: Configuration

```elixir
# config/config.exs
import Config

config :snakepit_showcase,
  ecto_repos: []

# Snakepit configuration
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 4,
    max_overflow: 2,
    strategy: :fifo,
    adapter_args: [
      "--adapter",
      "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"
    ]
  },
  grpc_port: 50051,
  grpc_host: "localhost"

# Phoenix configuration (if using web interface)
config :snakepit_showcase, SnakepitShowcase.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "development_secret_key_base_at_least_64_bytes_long_for_security",
  render_errors: [view: SnakepitShowcase.ErrorView, accepts: ~w(html json)],
  pubsub_server: SnakepitShowcase.PubSub,
  live_view: [signing_salt: "development_salt"]

# Configure telemetry
config :snakepit_showcase, :telemetry,
  metrics: true,
  logging: true

import_config "#{config_env()}.exs"
```

### Phase 3: Core Application Module

```elixir
# lib/snakepit_showcase/application.ex
defmodule SnakepitShowcase.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start Telemetry
      SnakepitShowcase.Telemetry,
      
      # Start PubSub
      {Phoenix.PubSub, name: SnakepitShowcase.PubSub},
      
      # Start the Endpoint (if using web interface)
      SnakepitShowcase.Endpoint,
      
      # Start Demo Supervisor
      {Task.Supervisor, name: SnakepitShowcase.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: SnakepitShowcase.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Phase 4: Demo Runner Framework

```elixir
# lib/snakepit_showcase/demo_runner.ex
defmodule SnakepitShowcase.DemoRunner do
  @moduledoc """
  Orchestrates running various Snakepit demonstrations.
  """
  
  alias SnakepitShowcase.Demos.{
    BasicDemo,
    SessionDemo,
    StreamingDemo,
    ConcurrentDemo,
    VariablesDemo,
    BinaryDemo,
    MLWorkflowDemo
  }

  @demos [
    {BasicDemo, "Basic Operations"},
    {SessionDemo, "Session Management"},
    {StreamingDemo, "Streaming Operations"},
    {ConcurrentDemo, "Concurrent Processing"},
    {VariablesDemo, "Variable Management"},
    {BinaryDemo, "Binary Serialization"},
    {MLWorkflowDemo, "ML Workflows"}
  ]

  def run_all do
    IO.puts("\n🎯 Snakepit Showcase - Running All Demos\n")
    
    Enum.each(@demos, fn {module, name} ->
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("📋 Demo: #{name}")
      IO.puts(String.duplicate("=", 60) <> "\n")
      
      case module.run() do
        :ok -> IO.puts("✅ #{name} completed successfully")
        {:error, reason} -> IO.puts("❌ #{name} failed: #{inspect(reason)}")
      end
      
      Process.sleep(1000)
    end)
  end

  def interactive do
    IO.puts("\n🎯 Snakepit Showcase - Interactive Mode\n")
    main_menu()
  end

  defp main_menu do
    IO.puts("\nSelect a demo to run:")
    
    @demos
    |> Enum.with_index(1)
    |> Enum.each(fn {{_module, name}, idx} ->
      IO.puts("  #{idx}. #{name}")
    end)
    
    IO.puts("  0. Exit")
    
    case IO.gets("\nEnter your choice: ") |> String.trim() |> Integer.parse() do
      {0, _} -> 
        IO.puts("👋 Goodbye!")
        :ok
        
      {choice, _} when choice > 0 and choice <= length(@demos) ->
        {module, name} = Enum.at(@demos, choice - 1)
        run_demo(module, name)
        main_menu()
        
      _ ->
        IO.puts("❌ Invalid choice. Please try again.")
        main_menu()
    end
  end

  defp run_demo(module, name) do
    IO.puts("\n" <> String.duplicate("-", 40))
    IO.puts("🚀 Running: #{name}")
    IO.puts(String.duplicate("-", 40) <> "\n")
    
    module.run()
    
    IO.puts("\n✅ Demo completed. Press Enter to continue...")
    IO.gets("")
  end
end
```

### Phase 5: Individual Demo Modules

#### Binary Serialization Demo (NEW)

```elixir
# lib/snakepit_showcase/demos/binary_demo.ex
defmodule SnakepitShowcase.Demos.BinaryDemo do
  @moduledoc """
  Demonstrates automatic binary serialization for large data.
  """

  def run do
    IO.puts("🔬 Binary Serialization Demo\n")
    
    # Create a session for our tests
    session_id = "binary_demo_#{System.unique_integer()}"
    
    # Demo 1: Small tensor (uses JSON)
    demo_small_tensor(session_id)
    
    # Demo 2: Large tensor (uses binary)
    demo_large_tensor(session_id)
    
    # Demo 3: Performance comparison
    demo_performance_comparison(session_id)
    
    # Demo 4: Embeddings
    demo_embeddings(session_id)
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup", %{})
    
    :ok
  end

  defp demo_small_tensor(session_id) do
    IO.puts("\n1️⃣ Small Tensor (JSON Encoding)")
    
    # Create a small tensor (< 10KB)
    start_time = System.monotonic_time(:millisecond)
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "create_tensor", %{
      name: "small_tensor",
      shape: [10, 10],
      size_bytes: 800  # 100 floats * 8 bytes
    })
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("   Created: #{result["name"]}")
    IO.puts("   Shape: #{inspect(result["shape"])}")
    IO.puts("   Size: #{result["size_bytes"]} bytes")
    IO.puts("   Encoding: #{result["encoding"]}")
    IO.puts("   Time: #{elapsed}ms")
  end

  defp demo_large_tensor(session_id) do
    IO.puts("\n2️⃣ Large Tensor (Binary Encoding)")
    
    # Create a large tensor (> 10KB)
    start_time = System.monotonic_time(:millisecond)
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "create_tensor", %{
      name: "large_tensor",
      shape: [100, 100],
      size_bytes: 80_000  # 10,000 floats * 8 bytes
    })
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("   Created: #{result["name"]}")
    IO.puts("   Shape: #{inspect(result["shape"])}")
    IO.puts("   Size: #{result["size_bytes"]} bytes")
    IO.puts("   Encoding: #{result["encoding"]}")
    IO.puts("   Time: #{elapsed}ms")
  end

  defp demo_performance_comparison(session_id) do
    IO.puts("\n3️⃣ Performance Comparison")
    
    sizes = [
      {[10, 10], "100 elements (800B)"},
      {[50, 50], "2,500 elements (20KB)"},
      {[100, 100], "10,000 elements (80KB)"},
      {[200, 200], "40,000 elements (320KB)"}
    ]
    
    IO.puts("\n   Shape      | Size       | JSON (ms) | Binary (ms) | Speedup")
    IO.puts("   -----------|------------|-----------|-------------|--------")
    
    Enum.each(sizes, fn {shape, desc} ->
      # Force JSON encoding
      json_time = measure_encoding(session_id, shape, false)
      
      # Force binary encoding
      binary_time = measure_encoding(session_id, shape, true)
      
      speedup = if binary_time > 0, do: json_time / binary_time, else: 0
      
      IO.puts("   #{inspect(shape)} | #{desc} | #{json_time} | #{binary_time} | #{:io_lib.format("~.1fx", [speedup])}")
    end)
  end

  defp demo_embeddings(session_id) do
    IO.puts("\n4️⃣ Embeddings Demo")
    
    # Create embeddings of different sizes
    embedding_sizes = [128, 512, 1024, 2048]
    
    IO.puts("\n   Testing embedding sizes...")
    
    Enum.each(embedding_sizes, fn size ->
      {:ok, result} = Snakepit.execute_in_session(session_id, "create_embedding", %{
        name: "embedding_#{size}",
        dimensions: size,
        batch_size: 32
      })
      
      IO.puts("   - #{size}D embedding (batch of 32):")
      IO.puts("     Encoding: #{result["encoding"]}")
      IO.puts("     Total size: #{result["total_bytes"]} bytes")
      IO.puts("     Processing time: #{result["time_ms"]}ms")
    end)
  end

  defp measure_encoding(session_id, shape, force_binary) do
    start_time = System.monotonic_time(:millisecond)
    
    Snakepit.execute_in_session(session_id, "benchmark_encoding", %{
      shape: shape,
      force_binary: force_binary
    })
    
    System.monotonic_time(:millisecond) - start_time
  end
end
```

### Phase 6: Python Adapters

#### Main Showcase Adapter

```python
# lib/snakepit_showcase/python_adapters/showcase_adapter.py
import numpy as np
import time
from typing import Dict, Any, List
from snakepit_bridge import Tool, SessionContext, StreamChunk

class ShowcaseAdapter:
    """Main adapter demonstrating all Snakepit features."""
    
    def __init__(self):
        self.tools = {
            # Basic operations
            "ping": Tool(self.ping),
            "echo": Tool(self.echo),
            "error_demo": Tool(self.error_demo),
            
            # Binary serialization demos
            "create_tensor": Tool(self.create_tensor),
            "create_embedding": Tool(self.create_embedding),
            "benchmark_encoding": Tool(self.benchmark_encoding),
            
            # Session operations
            "init_session": Tool(self.init_session),
            "cleanup": Tool(self.cleanup_session),
            
            # Streaming operations
            "stream_progress": Tool(self.stream_progress),
            "stream_data": Tool(self.stream_data),
            
            # ML operations
            "train_model": Tool(self.train_model),
            "predict": Tool(self.predict),
        }
    
    # Binary serialization methods
    def create_tensor(self, ctx: SessionContext, name: str, shape: List[int], 
                     size_bytes: int = None) -> Dict[str, Any]:
        """Create a tensor and demonstrate encoding detection."""
        # Generate random data
        total_elements = np.prod(shape)
        data = np.random.randn(*shape)
        
        # Calculate actual size
        actual_bytes = total_elements * 8  # float64
        
        # Register as tensor variable
        ctx.register_variable(name, "tensor", {
            "shape": shape,
            "data": data.tolist()
        })
        
        # Check which encoding was used (based on size)
        encoding = "binary" if actual_bytes > 10240 else "json"
        
        return {
            "name": name,
            "shape": shape,
            "size_bytes": actual_bytes,
            "encoding": encoding,
            "elements": total_elements
        }
    
    def create_embedding(self, ctx: SessionContext, name: str, 
                        dimensions: int, batch_size: int = 1) -> Dict[str, Any]:
        """Create embeddings and measure performance."""
        start_time = time.time()
        
        # Generate batch of embeddings
        embeddings = np.random.randn(batch_size, dimensions)
        
        # Flatten for storage as embedding type
        flat_embeddings = embeddings.flatten().tolist()
        
        # Register the embedding
        ctx.register_variable(name, "embedding", flat_embeddings)
        
        elapsed_ms = (time.time() - start_time) * 1000
        total_bytes = batch_size * dimensions * 8
        encoding = "binary" if total_bytes > 10240 else "json"
        
        return {
            "name": name,
            "dimensions": dimensions,
            "batch_size": batch_size,
            "total_bytes": total_bytes,
            "encoding": encoding,
            "time_ms": round(elapsed_ms, 2)
        }
    
    def benchmark_encoding(self, ctx: SessionContext, shape: List[int], 
                          force_binary: bool = False) -> Dict[str, Any]:
        """Benchmark encoding performance."""
        # Create data
        data = np.random.randn(*shape)
        
        # Force encoding type by manipulating size
        if force_binary and np.prod(shape) * 8 < 10240:
            # Pad data to force binary
            padding_needed = int(10240 / 8) - np.prod(shape)
            padded_data = np.concatenate([data.flatten(), np.zeros(padding_needed)])
            tensor_data = {"shape": shape + [padding_needed], "data": padded_data.tolist()}
        else:
            tensor_data = {"shape": shape, "data": data.tolist()}
        
        # Register and measure
        var_name = f"benchmark_{int(time.time() * 1000)}"
        ctx.register_variable(var_name, "tensor", tensor_data)
        
        return {"success": True}
    
    # Other demonstration methods...
    def ping(self, ctx: SessionContext, message: str = "pong") -> Dict[str, str]:
        return {"message": message, "timestamp": str(time.time())}
    
    def echo(self, ctx: SessionContext, **kwargs) -> Dict[str, Any]:
        return {"echoed": kwargs}
    
    def error_demo(self, ctx: SessionContext, error_type: str = "generic") -> None:
        if error_type == "value":
            raise ValueError("This is a demonstration ValueError")
        elif error_type == "runtime":
            raise RuntimeError("This is a demonstration RuntimeError")
        else:
            raise Exception("This is a generic exception")
    
    def stream_progress(self, ctx: SessionContext, steps: int = 10) -> StreamChunk:
        """Demonstrate streaming with progress updates."""
        for i in range(steps):
            progress = (i + 1) / steps * 100
            yield StreamChunk({
                "step": i + 1,
                "total": steps,
                "progress": round(progress, 1),
                "message": f"Processing step {i + 1}/{steps}"
            }, is_final=(i == steps - 1))
            time.sleep(0.1)
    
    # Additional methods for other demos...
```

### Phase 7: Web Interface (Optional but Recommended)

```elixir
# lib/snakepit_showcase/web/live/dashboard_live.ex
defmodule SnakepitShowcase.Web.DashboardLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :update_stats)
    end

    {:ok, assign(socket, 
      pool_stats: get_pool_stats(),
      demos: list_demos(),
      running_demo: nil,
      demo_output: []
    )}
  end

  @impl true
  def handle_event("run_demo", %{"demo" => demo_name}, socket) do
    # Run demo in background task
    Task.Supervisor.async_nolink(
      SnakepitShowcase.TaskSupervisor,
      fn -> run_demo(demo_name) end
    )
    
    {:noreply, assign(socket, running_demo: demo_name, demo_output: [])}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    # Demo completed
    Process.demonitor(ref, [:flush])
    
    output = socket.assigns.demo_output ++ [
      %{type: :success, message: "Demo completed successfully", timestamp: DateTime.utc_now()}
    ]
    
    {:noreply, assign(socket, running_demo: nil, demo_output: output)}
  end

  @impl true
  def handle_info(:update_stats, socket) do
    {:noreply, assign(socket, pool_stats: get_pool_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <h1>🐍 Snakepit Showcase Dashboard</h1>
      
      <div class="stats-grid">
        <div class="stat-card">
          <h3>Pool Status</h3>
          <dl>
            <dt>Active Workers:</dt>
            <dd><%= @pool_stats.active_workers %></dd>
            <dt>Available Workers:</dt>
            <dd><%= @pool_stats.available_workers %></dd>
            <dt>Queue Length:</dt>
            <dd><%= @pool_stats.queue_length %></dd>
          </dl>
        </div>
      </div>
      
      <div class="demos-section">
        <h2>Available Demos</h2>
        <div class="demo-grid">
          <%= for demo <- @demos do %>
            <div class="demo-card">
              <h3><%= demo.name %></h3>
              <p><%= demo.description %></p>
              <button 
                phx-click="run_demo" 
                phx-value-demo={demo.module}
                disabled={@running_demo != nil}
              >
                <%= if @running_demo == demo.module, do: "Running...", else: "Run Demo" %>
              </button>
            </div>
          <% end %>
        </div>
      </div>
      
      <div class="output-section">
        <h2>Demo Output</h2>
        <div class="output-console">
          <%= for entry <- @demo_output do %>
            <div class={"output-entry output-#{entry.type}"}>
              <span class="timestamp"><%= Calendar.strftime(entry.timestamp, "%H:%M:%S") %></span>
              <span class="message"><%= entry.message %></span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp get_pool_stats do
    # Implement pool statistics gathering
    %{
      active_workers: 0,
      available_workers: 4,
      queue_length: 0
    }
  end

  defp list_demos do
    [
      %{module: "BasicDemo", name: "Basic Operations", description: "Simple command execution and error handling"},
      %{module: "BinaryDemo", name: "Binary Serialization", description: "Large data handling with automatic binary encoding"},
      %{module: "StreamingDemo", name: "Streaming", description: "Real-time progress and chunked data"},
      %{module: "MLWorkflowDemo", name: "ML Workflows", description: "Complete machine learning pipeline"}
    ]
  end
end
```

### Phase 8: README for the Example

```markdown
# Snakepit Showcase

A comprehensive example application demonstrating all features of Snakepit, the high-performance process pooler for external language integrations.

## Features Demonstrated

- ✅ Basic command execution and error handling
- ✅ Session management and stateful operations
- ✅ Streaming with real-time progress updates
- ✅ Concurrent processing and pool management
- ✅ Variable management with type validation
- ✅ **Binary serialization for large data (NEW)**
- ✅ Complete ML workflows with DSPy integration
- ✅ Web dashboard for interactive exploration

## Quick Start

```bash
# Install dependencies
mix setup

# Run all demos
mix demo.all

# Interactive mode
mix demo.interactive

# Start with web dashboard
mix phx.server
# Visit http://localhost:4000
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

## Project Structure

- `lib/snakepit_showcase/demos/` - Individual demo modules
- `lib/snakepit_showcase/python_adapters/` - Python implementations
- `lib/snakepit_showcase/web/` - Phoenix LiveView dashboard
- `config/` - Application configuration

## Configuration

The showcase uses Snakepit as a path dependency:

```elixir
# mix.exs
{:snakepit, path: "../../"}
```

## Adding New Demos

1. Create a new module in `lib/snakepit_showcase/demos/`
2. Implement the `run/0` function
3. Add to the `@demos` list in `DemoRunner`
4. Optionally add Python methods to the adapter

## Learn More

- Main Snakepit documentation: `../../README.md`
- Binary serialization guide: `../../priv/python/BINARY_SERIALIZATION.md`
- Architecture overview: `../../ARCHITECTURE.md`
```

## Key Design Decisions

1. **Single Unified App**: All examples in one cohesive application instead of scattered scripts
2. **Path Dependency**: Uses `{:snakepit, path: "../../"}` to test against local development
3. **Optional Web UI**: Phoenix LiveView dashboard for visual interaction (can be omitted)
4. **Modular Demos**: Each feature in its own module for clarity
5. **Python Organization**: All Python code organized under the app structure
6. **Interactive & Batch**: Supports both interactive exploration and automated runs

## Benefits Over Current Examples

1. **Cohesion**: Single app shows how features work together
2. **Real-world Structure**: Demonstrates proper Elixir app organization
3. **Better Testing**: Can write proper tests for examples
4. **Documentation**: Self-documenting through module docs and README
5. **Extensibility**: Easy to add new feature demos
6. **Binary Demo**: Showcases the new binary serialization with benchmarks

## Migration Path

1. Create the new `snakepit_showcase` app structure
2. Port each existing example script to a demo module
3. Add the new binary serialization demo
4. Test all demos work correctly
5. Update main README to point to showcase
6. Delete old example scripts

This design provides a professional, maintainable example that developers can use as a reference implementation for their own Snakepit-based applications.
