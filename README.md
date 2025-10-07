# Snakepit 🐍

<div align="center">
  <img src="assets/snakepit-logo.svg" alt="Snakepit Logo" width="200" height="200">
</div>

> A high-performance, generalized process pooler and session manager for external language integrations in Elixir

[![CI](https://github.com/nshkrdotcom/snakepit/actions/workflows/ci.yml/badge.svg)](https://github.com/nshkrdotcom/snakepit/actions/workflows/ci.yml)
[![Hex Version](https://img.shields.io/hexpm/v/snakepit.svg)](https://hex.pm/packages/snakepit)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## 🚀 What is Snakepit?

Snakepit is a battle-tested Elixir library that provides a robust pooling system for managing external processes (Python, Node.js, Ruby, R, etc.). Born from the need for reliable ML/AI integrations, it offers:

- **Lightning-fast concurrent initialization** - 1000x faster than sequential approaches
- **Session-based execution** with automatic worker affinity
- **gRPC-based communication** - Modern HTTP/2 protocol with streaming support
- **Native streaming support** - Real-time progress updates and progressive results (gRPC)
- **Adapter pattern** for any external language/runtime
- **Built on OTP primitives** - DynamicSupervisor, Registry, GenServer
- **Production-ready** with telemetry, health checks, and graceful shutdowns

## 📋 Table of Contents

- [What's New in v0.4](#whats-new-in-v04)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Core Concepts](#core-concepts)
- [Configuration](#configuration)
- [Usage Examples](#usage-examples)
- [gRPC Communication](#grpc-communication)
- [Python Bridges](#python-bridges)
  - [Bidirectional Tool Bridge](#bidirectional-tool-bridge)
- [Built-in Adapters](#built-in-adapters)
- [Creating Custom Adapters](#creating-custom-adapters)
- [Session Management](#session-management)
- [Monitoring & Telemetry](#monitoring--telemetry)
- [Architecture Deep Dive](#architecture-deep-dive)
- [Performance](#performance)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## 🆕 What's New in v0.4.1

### 🚀 **Enhanced Tool Bridge Functionality**
- **New `process_text` tool** - Text processing with upper, lower, reverse, length operations
- **New `get_stats` tool** - Real-time adapter and system monitoring with memory/CPU usage
- **Fixed gRPC tool registration** - Resolved async/sync issues with UnaryUnaryCall objects
- **Automatic session initialization** - Sessions created automatically when Python tools register

### 🔧 **Tool Bridge Improvements**
- **Remote tool dispatch** - Complete bidirectional communication between Elixir and Python
- **Missing tool recovery** - Added adapter_info, echo, process_text, get_stats to ShowcaseAdapter
- **Async/sync compatibility** - Fixed gRPC stub handling with proper response processing
- **Enhanced error handling** - Better diagnostics for tool registration failures

## 🆕 What's New in v0.4

### 🛡️ **Enhanced Process Management & Reliability**
- **Persistent process tracking** with DETS storage survives BEAM crashes
- **Automatic orphan cleanup** - no more zombie Python processes
- **Pre-registration pattern** - Prevents orphans even during startup crashes
- **Immediate DETS persistence** - No data loss on abrupt termination
- **Zero-configuration reliability** - works out of the box
- **Production-ready** - handles VM crashes, OOM kills, and power failures
- See [Process Management Documentation](README_PROCESS_MANAGEMENT.md) for details

### 🌊 **Native gRPC Streaming**
- **Real-time progress updates** for long-running operations
- **HTTP/2 multiplexing** for concurrent requests
- **Cancellable operations** with graceful stream termination
- **Built-in health checks** and rich error handling

### 🚀 **Binary Serialization for Large Data**
- **Automatic binary encoding** for tensors and embeddings > 10KB
- **5-10x faster** than JSON for large numerical arrays
- **Zero configuration** - works automatically
- **Backward compatible** - smaller data still uses JSON
- **Modern architecture** with protocol buffers

### 📦 **High-Performance Design**
- **Efficient binary transfers** with protocol buffers
- **HTTP/2 multiplexing** for concurrent operations
- **Native binary data handling** perfect for ML models and images
- **18-36% smaller message sizes** for improved performance

### 🎯 **Comprehensive Showcase Application**
- **Complete example app** at `examples/snakepit_showcase`
- **Demonstrates all features** including binary serialization
- **Performance benchmarks** showing 5-10x speedup
- **Ready-to-run demos** for all Snakepit capabilities

### 🐍 **Python Bridge V2 Architecture**
- **Production-ready packaging** with pip install support
- **Enhanced error handling** and robust shutdown management
- **Console script integration** for deployment flexibility
- **Type checking support** with proper py.typed markers

### 🔄 **Bridge Migration & Compatibility**
- **Deprecated V1 Python bridge** in favor of V2 architecture
- **Updated demo implementations** using latest best practices
- **Comprehensive documentation** for all bridge implementations
- **Backward compatibility** maintained for existing integrations

### 🔀 **Bidirectional Tool Bridge (NEW)**
- **Cross-language function execution** - Call Python from Elixir and vice versa
- **Transparent tool proxying** - Remote functions appear as local functions
- **Session-scoped isolation** - Tools are isolated by session for multi-tenancy
- **Dynamic discovery** - Automatic tool discovery and registration
- See [Bidirectional Tool Bridge Documentation](README_BIDIRECTIONAL_TOOL_BRIDGE.md) for details

## 🏃 Quick Start

```elixir
# In your mix.exs
def deps do
  [
    {:snakepit, "~> 0.4.1"}
  ]
end

# Configure with gRPC adapter
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50051,
  port_range: 100
})
Application.put_env(:snakepit, :pool_config, %{pool_size: 4})

{:ok, _} = Application.ensure_all_started(:snakepit)

# Execute commands with gRPC
{:ok, result} = Snakepit.execute("ping", %{test: true})
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})

# Session-based execution (maintains state)
{:ok, result} = Snakepit.execute_in_session("user_123", "echo", %{message: "hello"})

# Streaming operations for real-time updates
Snakepit.execute_stream("batch_process", %{items: [1, 2, 3]}, fn chunk ->
  IO.puts("Progress: #{chunk["progress"]}%")
end)
```

## 📦 Installation

### Hex Package

```elixir
def deps do
  [
    {:snakepit, "~> 0.4.1"}
  ]
end
```

### GitHub (Latest)

```elixir
def deps do
  [
    {:snakepit, github: "nshkrdotcom/snakepit"}
  ]
end
```

### Requirements

- Elixir 1.18+
- Erlang/OTP 27+
- External runtime (Python 3.8+, Node.js 16+, etc.) depending on adapter

> **📘 For detailed installation instructions** (including platform-specific guides for Ubuntu, macOS, Windows/WSL, Docker, virtual environments, and troubleshooting), see the **[Complete Installation Guide](docs/INSTALLATION.md)**.

## 🛠️ Quick Setup

### Step 1: Install Python Dependencies

For Python/gRPC integration (recommended):

```bash
# Install Python dependencies
pip install grpcio grpcio-tools protobuf numpy

# Or use the provided requirements file
cd deps/snakepit/priv/python
pip install -r requirements.txt
```

**Virtual Environment (Recommended)**:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r deps/snakepit/priv/python/requirements.txt
```

### Step 2: Generate Protocol Buffers

```bash
# Generate Python gRPC code
make proto-python

# This creates the necessary gRPC stubs in priv/python/
```

### Step 3: Configure Your Application

Add to your `config/config.exs`:

```elixir
config :snakepit,
  # Enable pooling (recommended for production)
  pooling_enabled: true,
  
  # Choose your adapter
  adapter_module: Snakepit.Adapters.GRPCPython,
  
  # Pool configuration
  pool_config: %{
    pool_size: System.schedulers_online() * 2,
    startup_timeout: 10_000,
    max_queue_size: 1000
  },
  
  # gRPC configuration
  grpc_config: %{
    base_port: 50051,
    port_range: 100,
    connect_timeout: 5_000
  },
  
  # Session configuration
  session_config: %{
    ttl: 3600,  # 1 hour default
    cleanup_interval: 60_000  # 1 minute
  }
```

### Step 4: Start Snakepit

In your application supervisor:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Other children...
      {Snakepit.Application, []}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

Or start manually:

```elixir
{:ok, _} = Application.ensure_all_started(:snakepit)
```

### Step 5: Verify Installation

```bash
# Verify Python dependencies
python3 -c "import grpc; print('✅ gRPC installed:', grpc.__version__)"

# Run tests
mix test

# Try an example
elixir examples/grpc_basic.exs
```

**Expected output**: Should see gRPC connections and successful command execution.

> **💡 Troubleshooting**: If you see `ModuleNotFoundError: No module named 'grpc'`, the Python dependencies aren't installed. See [Installation Guide](docs/INSTALLATION.md#troubleshooting) for help.

### Step 6: Create a Custom Adapter (Optional)

For custom Python functionality:

```python
# priv/python/my_adapter.py
from snakepit_bridge.adapters.base import BaseAdapter

class MyAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        # Initialize your libraries here
        
    async def execute_my_command(self, args):
        # Your custom logic
        result = do_something(args)
        return {"status": "success", "result": result}
```

Configure it:

```elixir
# config/config.exs
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  python_adapter: "my_adapter:MyAdapter"
```

### Step 6: Verify Installation

```elixir
# In IEx
iex> Snakepit.execute("ping", %{})
{:ok, %{"status" => "pong", "timestamp" => 1234567890}}
```

## 🎯 Core Concepts

### 1. **Adapters**
Adapters define how Snakepit communicates with external processes. They specify:
- The runtime executable (python3, node, ruby, etc.)
- The bridge script to execute
- Supported commands and validation
- Request/response transformations

### 2. **Workers**
Each worker is a GenServer that:
- Owns one external process via Erlang Port
- Handles request/response communication
- Manages health checks and metrics
- Auto-restarts on crashes

### 3. **Pool**
The pool manager:
- Starts workers concurrently on initialization
- Routes requests to available workers
- Handles queueing when all workers are busy
- Supports session affinity for stateful operations

### 4. **Sessions**
Sessions provide:
- State persistence across requests
- Worker affinity (same session prefers same worker)
- TTL-based expiration
- Centralized storage in ETS

## ⚙️ Configuration

### Basic Configuration

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,  # gRPC-based communication
  grpc_config: %{
    base_port: 50051,    # Starting port for gRPC servers
    port_range: 100      # Port range for worker allocation
  },
  pool_config: %{
    pool_size: 8  # Default: System.schedulers_online() * 2
  }
```

### gRPC Configuration

```elixir
# gRPC-specific configuration
config :snakepit,
  grpc_config: %{
    base_port: 50051,       # Starting port for gRPC servers
    port_range: 100,        # Port range for worker allocation
    connect_timeout: 5000,  # Connection timeout in ms
    request_timeout: 30000  # Default request timeout in ms
  }
```

The gRPC adapter automatically assigns unique ports to each worker within the specified range, ensuring isolation and parallel operation.

### Advanced Configuration

```elixir
config :snakepit,
  # Pool settings
  pooling_enabled: true,
  pool_config: %{
    pool_size: 16
  },
  
  # Adapter
  adapter_module: MyApp.CustomAdapter,
  
  # Timeouts (milliseconds)
  pool_startup_timeout: 10_000,      # Max time for worker initialization
  pool_queue_timeout: 5_000,         # Max time in request queue
  worker_init_timeout: 20_000,       # Max time for worker to respond to init
  worker_health_check_interval: 30_000,  # Health check frequency
  worker_shutdown_grace_period: 2_000,   # Grace period for shutdown
  
  # Cleanup settings
  cleanup_retry_interval: 100,       # Retry interval for cleanup
  cleanup_max_retries: 10,          # Max cleanup retries
  
  # Queue management
  pool_max_queue_size: 1000         # Max queued requests before rejection
```

### Runtime Configuration

```elixir
# Override configuration at runtime
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)
Application.stop(:snakepit)
Application.start(:snakepit)
```

## 📖 Usage Examples

### Running the Examples

All examples are ready to run from the command line:

```bash
# Basic gRPC operations (ping, echo, add)
elixir examples/grpc_basic.exs

# Concurrent execution and pool utilization (default: 4 workers)
elixir examples/grpc_concurrent.exs

# High-concurrency test (100 workers)
elixir examples/grpc_concurrent.exs 100

# Stress test (120 workers on fast machine)
elixir examples/grpc_concurrent.exs 120

# Session management and affinity
elixir examples/grpc_sessions.exs

# Streaming operations
elixir examples/grpc_streaming.exs

# Variable system demonstration
elixir examples/grpc_variables.exs

# Bidirectional tool bridge (Elixir ↔ Python)
elixir examples/bidirectional_tools_demo.exs
```

**Prerequisites**: Python dependencies installed (see [Installation Guide](docs/INSTALLATION.md))

**Expected**: Each example demonstrates specific Snakepit features with clear output.

**Performance Notes**:
- 100 workers initialize in ~3-4 seconds
- Concurrent operations scale linearly with pool size
- Tests show 1000x speedup vs sequential initialization

### Code Examples

#### Simple Command Execution

```elixir
# Basic ping/pong
{:ok, result} = Snakepit.execute("ping", %{})
# => %{"status" => "pong", "timestamp" => 1234567890}

# Computation
{:ok, result} = Snakepit.execute("compute", %{
  operation: "multiply",
  a: 7,
  b: 6
})
# => %{"result" => 42}

# With error handling
case Snakepit.execute("risky_operation", %{threshold: 0.5}) do
  {:ok, result} -> 
    IO.puts("Success: #{inspect(result)}")
  {:error, :worker_timeout} -> 
    IO.puts("Operation timed out")
  {:error, {:worker_error, msg}} -> 
    IO.puts("Worker error: #{msg}")
  {:error, reason} -> 
    IO.puts("Failed: #{inspect(reason)}")
end
```

#### Running Scripts and Demos

For short-lived scripts, Mix tasks, or demos that need to execute and exit cleanly, use `run_as_script/2`:

```elixir
# In a Mix task or script
Snakepit.run_as_script(fn ->
  # Your code here - all workers will be properly cleaned up on exit
  {:ok, result} = Snakepit.execute("process_data", %{data: large_dataset})
  IO.inspect(result)
end)

# With custom timeout for pool initialization
Snakepit.run_as_script(fn ->
  results = Enum.map(1..100, fn i ->
    {:ok, result} = Snakepit.execute("compute", %{value: i})
    result
  end)
  IO.puts("Processed #{length(results)} items")
end, timeout: 30_000)
```

This ensures:
- The pool waits for all workers to be ready before executing
- All Python/external processes are properly terminated on exit
- No orphaned processes remain after your script completes

#### Session-Based State Management

```elixir
# Create a session with variables
session_id = "analysis_#{UUID.generate()}"

# Initialize session with variables
{:ok, _} = Snakepit.Bridge.SessionStore.create_session(session_id)
{:ok, _} = Snakepit.Bridge.SessionStore.register_variable(
  session_id, 
  "temperature", 
  :float, 
  0.7,
  constraints: %{min: 0.0, max: 1.0}
)

# Execute commands that use session variables
{:ok, result} = Snakepit.execute_in_session(session_id, "generate_text", %{
  prompt: "Tell me about Elixir"
})

# Update variables
:ok = Snakepit.Bridge.SessionStore.update_variable(session_id, "temperature", 0.9)

# List all variables
{:ok, vars} = Snakepit.Bridge.SessionStore.list_variables(session_id)

# Cleanup when done
:ok = Snakepit.Bridge.SessionStore.delete_session(session_id)
```

### ML/AI Workflow Example

```elixir
# Using SessionHelpers for ML program management
alias Snakepit.SessionHelpers

# Create an ML program/model
{:ok, response} = SessionHelpers.execute_program_command(
  "ml_session_123",
  "create_program",
  %{
    signature: "question -> answer",
    model: "gpt-3.5-turbo",
    temperature: 0.7
  }
)

program_id = response["program_id"]

# Execute the program multiple times
{:ok, result} = SessionHelpers.execute_program_command(
  "ml_session_123", 
  "execute_program",
  %{
    program_id: program_id,
    input: %{question: "What is the capital of France?"}
  }
)
```

### High-Performance Streaming with gRPC

```elixir
# Configure gRPC adapter for streaming workloads
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50051,
  port_range: 100
})

# Process large datasets with streaming
Snakepit.execute_stream("process_dataset", %{
  file_path: "/data/large_dataset.csv",
  chunk_size: 1000
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("Processing complete: #{chunk["total_processed"]} records")
  else
    IO.puts("Progress: #{chunk["progress"]}% - #{chunk["records_processed"]}/#{chunk["total_records"]}")
  end
end)

# ML inference with real-time results
Snakepit.execute_stream("batch_inference", %{
  model_path: "/models/resnet50.pkl",
  images: ["img1.jpg", "img2.jpg", "img3.jpg"]
}, fn chunk ->
  IO.puts("Processed #{chunk["image"]}: #{chunk["prediction"]} (#{chunk["confidence"]}%)")
end)
```

### Parallel Processing

```elixir
# Process multiple items in parallel across the pool
items = ["item1", "item2", "item3", "item4", "item5"]

tasks = Enum.map(items, fn item ->
  Task.async(fn ->
    Snakepit.execute("process_item", %{item: item})
  end)
end)

results = Task.await_many(tasks, 30_000)
```

## 🌊 gRPC Communication

Snakepit supports modern gRPC-based communication for advanced streaming capabilities, real-time progress updates, and superior performance.

### 🚀 **Getting Started with gRPC**

#### Upgrade to gRPC (3 Steps):
```bash
# Step 1: Install gRPC dependencies
make install-grpc

# Step 2: Generate protocol buffer code
make proto-python

# Step 3: Test the upgrade
elixir examples/grpc_non_streaming_demo.exs
```

#### New Configuration (gRPC):
```elixir
# Replace your adapter configuration with this:
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50051,
  port_range: 100
})

# ✅ ALL your existing API calls work EXACTLY the same
{:ok, result} = Snakepit.execute("ping", %{})
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})

# 🆕 PLUS you get new streaming capabilities
Snakepit.execute_stream("batch_inference", %{
  batch_items: ["image1.jpg", "image2.jpg", "image3.jpg"]
}, fn chunk ->
  IO.puts("Processed: #{chunk["item"]} - #{chunk["confidence"]}")
end)
```

### 📋 **gRPC Features**

| Feature | gRPC Non-Streaming | gRPC Streaming |
|---------|-------------------|----------------|
| **Standard API** | ✅ Full support | ✅ Full support |
| **Streaming** | ❌ | ✅ **Real-time** |
| **HTTP/2 Multiplexing** | ✅ | ✅ |
| **Progress Updates** | ❌ | ✅ **Live Updates** |
| **Health Checks** | ✅ Built-in | ✅ Built-in |
| **Error Handling** | ✅ Rich Status | ✅ Rich Status |

### 🎯 **Two gRPC Modes Explained**

#### **Mode 1: gRPC Non-Streaming** 
**Use this for:** Standard request-response operations
```elixir
# Standard API for quick operations
{:ok, result} = Snakepit.execute("ping", %{})
{:ok, result} = Snakepit.execute("compute", %{operation: "multiply", a: 10, b: 5})
{:ok, result} = Snakepit.execute("info", %{})

# Session support works exactly the same
{:ok, result} = Snakepit.execute_in_session("user_123", "echo", %{message: "hello"})
```

**When to use:**
- ✅ You want better performance without changing your code
- ✅ Your operations complete quickly (< 30 seconds)
- ✅ You don't need progress updates
- ✅ Standard request-response pattern

#### **Mode 2: gRPC Streaming** 
**Use this for:** Long-running operations with real-time progress updates
```elixir
# NEW streaming API - get results as they complete
Snakepit.execute_stream("batch_inference", %{
  batch_items: ["img1.jpg", "img2.jpg", "img3.jpg"]
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("✅ All done!")
  else
    IO.puts("🧠 Processed: #{chunk["item"]} - #{chunk["confidence"]}")
  end
end)

# Session-based streaming also available
Snakepit.execute_in_session_stream("session_123", "process_large_dataset", %{
  file_path: "/data/huge_file.csv"
}, fn chunk ->
  IO.puts("📊 Progress: #{chunk["progress_percent"]}%")
end)
```

**When to use:**
- ✅ Long-running operations (ML training, data processing)
- ✅ You want real-time progress updates
- ✅ Processing large datasets or batches
- ✅ Better user experience with live feedback

### 🛠️ **Setup Instructions**

#### Install gRPC Dependencies
```bash
# Install gRPC dependencies
make install-grpc

# Generate protocol buffer code
make proto-python

# Verify with non-streaming demo (same as your existing API)
elixir examples/grpc_non_streaming_demo.exs

# Try new streaming capabilities
elixir examples/grpc_streaming_demo.exs
```

### 📝 **Complete Examples**

#### **Non-Streaming Examples (Standard API)**
```elixir
# Configure gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{base_port: 50051, port_range: 100})

# All your existing code works unchanged
{:ok, result} = Snakepit.execute("ping", %{})
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})
{:ok, result} = Snakepit.execute("info", %{})

# Sessions work exactly the same
{:ok, result} = Snakepit.execute_in_session("session_123", "echo", %{message: "hello"})

# Try it: elixir examples/grpc_non_streaming_demo.exs
```

#### **Streaming Examples (New Capability)**

**ML Batch Inference with Real-time Progress:**
```elixir
# Process multiple items, get results as each completes
Snakepit.execute_stream("batch_inference", %{
  model_path: "/models/resnet50.pkl",
  batch_items: ["img1.jpg", "img2.jpg", "img3.jpg"]
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("✅ All #{chunk["total_processed"]} items complete!")
  else
    IO.puts("🧠 #{chunk["item"]}: #{chunk["prediction"]} (#{chunk["confidence"]})")
  end
end)
```

**Large Dataset Processing with Progress:**
```elixir
# Process huge datasets, see progress in real-time
Snakepit.execute_stream("process_large_dataset", %{
  file_path: "/data/huge_dataset.csv",
  chunk_size: 5000
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("🎉 Processing complete: #{chunk["final_stats"]}")
  else
    progress = chunk["progress_percent"]
    IO.puts("📊 Progress: #{progress}% (#{chunk["processed_rows"]}/#{chunk["total_rows"]})")
  end
end)
```

**Session-based Streaming:**
```elixir
# Streaming with session state
session_id = "ml_training_#{user_id}"

Snakepit.execute_in_session_stream(session_id, "distributed_training", %{
  model_config: training_config,
  dataset_path: "/data/training_set"
}, fn chunk ->
  if chunk["is_final"] do
    model_path = chunk["final_model_path"]
    IO.puts("🎯 Training complete! Model saved: #{model_path}")
  else
    epoch = chunk["epoch"]
    loss = chunk["train_loss"]
    acc = chunk["val_acc"]
    IO.puts("📈 Epoch #{epoch}: loss=#{loss}, acc=#{acc}")
  end
end)

# Try it: elixir examples/grpc_streaming_demo.exs
```

### 🚀 **Performance & Benefits**

#### **Why Upgrade to gRPC?**

**gRPC Non-Streaming:**
- ✅ **Better performance**: HTTP/2 multiplexing, protocol buffers
- ✅ **Built-in health checks**: Automatic worker monitoring
- ✅ **Rich error handling**: Detailed gRPC status codes
- ✅ **Zero code changes**: Drop-in replacement

**gRPC Streaming vs Traditional (All Protocols):**
- ✅ **Progressive results**: Get updates as work completes
- ✅ **Constant memory**: Process unlimited data without memory growth
- ✅ **Real-time feedback**: Users see progress immediately
- ✅ **Cancellable operations**: Stop long-running tasks mid-stream
- ✅ **Better UX**: No more "is it still working?" uncertainty

#### **Performance Comparison:**
```
Traditional (blocking):  Submit → Wait 10 minutes → Get all results
gRPC Non-streaming:     Submit → Get result faster (better protocol)
gRPC Streaming:         Submit → Get result 1 → Get result 2 → ...

Memory usage:           Fixed vs Grows with result size vs Constant
User experience:        "Wait..." vs "Wait..." vs Real-time updates
Cancellation:           Kill process vs Kill process vs Graceful stream close
```

### 📋 **Quick Decision Guide**

**Choose your mode based on your needs:**

| **Your Situation** | **Recommended Mode** | **Why** |
|-------------------|---------------------|---------|
| Quick operations (< 30s) | **gRPC Non-Streaming** | Low latency, simple API |
| Want better performance, same API | **gRPC Non-Streaming** | Drop-in upgrade |
| Need progress updates | **gRPC Streaming** | Real-time feedback |
| Long-running ML tasks | **gRPC Streaming** | See progress, cancel if needed |
| Quick operations (< 30s) | gRPC Non-Streaming | No streaming overhead |
| Large dataset processing | **gRPC Streaming** | Memory efficient |

**Migration path:**

### gRPC Dependencies

**Elixir:**
```elixir
# mix.exs
def deps do
  [
    {:grpc, "~> 0.8"},
    {:protobuf, "~> 0.12"},
    # ... other deps
  ]
end
```

**Python:**
```bash
# Install with gRPC support
pip install 'snakepit-bridge[grpc]'

# Or manually
pip install grpcio protobuf grpcio-tools
```

### Available Streaming Commands

| Command | Description | Use Case |
|---------|-------------|----------|
| `ping_stream` | Heartbeat stream | Testing, monitoring |
| `batch_inference` | ML model inference | Computer vision, NLP |
| `process_large_dataset` | Data processing | ETL, analytics |
| `tail_and_analyze` | Log analysis | Real-time monitoring |
| `distributed_training` | ML training | Neural networks |

For comprehensive gRPC documentation, see **[README_GRPC.md](README_GRPC.md)**.

## 🚀 Binary Serialization

Snakepit automatically optimizes large data transfers using binary serialization:

### Automatic Optimization

```elixir
# Small tensor (<10KB) - uses JSON automatically
{:ok, result} = Snakepit.execute("create_tensor", %{
  shape: [10, 10],  # 100 elements = 800 bytes
  name: "small_tensor"
})

# Large tensor (>10KB) - uses binary automatically
{:ok, result} = Snakepit.execute("create_tensor", %{
  shape: [100, 100],  # 10,000 elements = 80KB
  name: "large_tensor"
})

# Performance: 5-10x faster for large data!
```

### ML/AI Use Cases

```elixir
# Embeddings - automatic binary for large batches
{:ok, embeddings} = Snakepit.execute("generate_embeddings", %{
  texts: ["sentence 1", "sentence 2", ...],  # 100+ sentences
  model: "sentence-transformers/all-MiniLM-L6-v2",
  dimensions: 384
})

# Image processing - binary for pixel data
{:ok, result} = Snakepit.execute("process_images", %{
  images: ["image1.jpg", "image2.jpg"],
  return_tensors: true  # Returns large tensors via binary
})
```

### Performance Benchmarks

| Data Size | JSON Time | Binary Time | Speedup |
|-----------|-----------|-------------|---------|
| 800B | 12ms | 15ms | 0.8x |
| 20KB | 45ms | 18ms | 2.5x |
| 80KB | 156ms | 22ms | 7.1x |
| 320KB | 642ms | 38ms | 16.9x |

### How It Works

1. **Automatic Detection**: Data size calculated on serialization
2. **Threshold**: 10KB (10,240 bytes)
3. **Formats**: 
   - Small data: JSON (human-readable, debuggable)
   - Large data: Binary (Pickle on Python, ETF on Elixir)
4. **Zero Configuration**: Works out of the box

For detailed binary serialization documentation, see **[priv/python/BINARY_SERIALIZATION.md](priv/python/BINARY_SERIALIZATION.md)**.

## 🎯 Showcase Application

Explore all Snakepit features with our comprehensive showcase application:

### Quick Start

```bash
# Navigate to showcase
cd examples/snakepit_showcase

# Install and run
mix setup
mix demo.all

# Or interactive mode
mix demo.interactive
```

### Available Demos

1. **Basic Operations** - Health checks, error handling
2. **Session Management** - Stateful operations, worker affinity  
3. **Streaming Operations** - Real-time progress, chunked data
4. **Concurrent Processing** - Parallel execution, pool management
5. **Variable Management** - Type system, constraints, validation
6. **Binary Serialization** - Performance benchmarks, large data handling
7. **ML Workflows** - Complete pipelines, DSPy integration

### Binary Demo Highlights

```bash
mix run -e "SnakepitShowcase.Demos.BinaryDemo.run()"
```

Shows:
- Automatic JSON vs binary detection
- Side-by-side performance comparison
- Real-world ML embedding examples
- Memory efficiency metrics

See **[examples/snakepit_showcase/README.md](examples/snakepit_showcase/README.md)** for full documentation.

## 🐍 Python Bridges

For detailed documentation on all Python bridge implementations (V1, V2, Enhanced, gRPC), see the Python Bridges section below.

### 🔄 Bidirectional Tool Bridge

Snakepit supports transparent cross-language function execution between Elixir and Python:

```elixir
# Call Python functions from Elixir
{:ok, result} = ToolRegistry.execute_tool(session_id, "python_ml_function", %{data: input})

# Python can call Elixir functions transparently
# result = ctx.call_elixir_tool("parse_json", json_string='{"test": true}')
```

For comprehensive documentation on the bidirectional tool bridge, see **[README_BIDIRECTIONAL_TOOL_BRIDGE.md](README_BIDIRECTIONAL_TOOL_BRIDGE.md)**.

## 🔌 Built-in Adapters

### gRPC Python Adapter (Streaming Specialist)

```elixir
# Configure with gRPC for dedicated streaming and advanced features
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{base_port: 50051, port_range: 100})

# Dedicated streaming capabilities
{:ok, _} = Snakepit.execute_stream("batch_inference", %{
  batch_items: ["img1.jpg", "img2.jpg", "img3.jpg"]
}, fn chunk ->
  IO.puts("Processed: #{chunk["item"]} - #{chunk["confidence"]}")
end)
```

#### gRPC Features
- ✅ **Native streaming** - Progressive results and real-time updates
- ✅ **HTTP/2 multiplexing** - Multiple concurrent requests per connection
- ✅ **Built-in health checks** - Automatic worker health monitoring
- ✅ **Rich error handling** - gRPC status codes with detailed context
- ✅ **Protocol buffers** - Efficient binary serialization
- ✅ **Cancellable operations** - Stop long-running tasks gracefully
- ✅ **Custom adapter support** - Use third-party Python adapters via pool configuration

#### Custom Adapter Support (v0.3.3+)

The gRPC adapter now supports custom Python adapters through pool configuration:

```elixir
# Configure with a custom Python adapter (e.g., DSPy integration)
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: 4,
  adapter_args: ["--adapter", "snakepit_bridge.adapters.dspy_grpc.DSPyGRPCHandler"]
})

# The adapter can provide custom commands beyond the standard set
{:ok, result} = Snakepit.Python.call("dspy.Predict", %{signature: "question -> answer"})
{:ok, result} = Snakepit.Python.call("stored.predictor.__call__", %{question: "What is DSPy?"})
```

##### Available Custom Adapters

- **`snakepit_bridge.adapters.dspy_grpc.DSPyGRPCHandler`** - DSPy integration for declarative language model programming
  - Supports DSPy modules (Predict, ChainOfThought, ReAct, etc.)
  - Python API with `call`, `store`, `retrieve` commands
  - Automatic signature parsing and field mapping
  - Session management for stateful operations

#### Installation & Usage

```bash
# Install gRPC dependencies
make install-grpc

# Generate protocol buffer code  
make proto-python

# Test with streaming demo
elixir examples/grpc_streaming_demo.exs

# Test with non-streaming demo
elixir examples/grpc_non_streaming_demo.exs
```

### JavaScript/Node.js Adapter

```elixir
# Configure
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)

# Additional commands
{:ok, _} = Snakepit.execute("random", %{type: "uniform", min: 0, max: 100})
{:ok, _} = Snakepit.execute("compute", %{operation: "sqrt", a: 16})
```

## 🛠️ Creating Custom Adapters

### Complete Custom Adapter Example

Here's a real-world example of a data science adapter with session support:

```python
# priv/python/data_science_adapter.py
import pandas as pd
import numpy as np
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from snakepit_bridge.adapters.base import BaseAdapter
from snakepit_bridge.session_context import SessionContext

class DataScienceAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        self.models = {}  # Store trained models per session
        
    def set_session_context(self, context: SessionContext):
        """Called when a session context is available."""
        self.session_context = context
        
    async def execute_load_data(self, args):
        """Load data from CSV and store in session."""
        file_path = args.get("file_path")
        if not file_path:
            raise ValueError("file_path is required")
            
        # Load data
        df = pd.read_csv(file_path)
        
        # Store basic info in session variables
        if self.session_context:
            await self.session_context.register_variable(
                "data_shape", "list", list(df.shape)
            )
            await self.session_context.register_variable(
                "columns", "list", df.columns.tolist()
            )
            
        return {
            "rows": len(df),
            "columns": len(df.columns),
            "column_names": df.columns.tolist(),
            "dtypes": df.dtypes.to_dict()
        }
        
    async def execute_preprocess(self, args):
        """Preprocess data with scaling."""
        data = args.get("data")
        target_column = args.get("target")
        
        # Convert to DataFrame
        df = pd.DataFrame(data)
        
        # Separate features and target
        X = df.drop(columns=[target_column])
        y = df[target_column]
        
        # Scale features
        scaler = StandardScaler()
        X_scaled = scaler.fit_transform(X)
        
        # Store scaler parameters in session
        if self.session_context:
            session_id = self.session_context.session_id
            self.models[f"{session_id}_scaler"] = scaler
            
        # Split data
        X_train, X_test, y_train, y_test = train_test_split(
            X_scaled, y, test_size=0.2, random_state=42
        )
        
        return {
            "train_size": len(X_train),
            "test_size": len(X_test),
            "feature_means": scaler.mean_.tolist(),
            "feature_stds": scaler.scale_.tolist()
        }
        
    async def execute_train_model(self, args):
        """Train a model and store it."""
        model_type = args.get("model_type", "linear_regression")
        hyperparams = args.get("hyperparams", {})
        
        # Import the appropriate model
        if model_type == "linear_regression":
            from sklearn.linear_model import LinearRegression
            model = LinearRegression(**hyperparams)
        elif model_type == "random_forest":
            from sklearn.ensemble import RandomForestRegressor
            model = RandomForestRegressor(**hyperparams)
        else:
            raise ValueError(f"Unknown model type: {model_type}")
            
        # Train model (assume data is passed or stored)
        # ... training logic ...
        
        # Store model in session
        if self.session_context:
            session_id = self.session_context.session_id
            model_id = f"{session_id}_{model_type}"
            self.models[model_id] = model
            
            # Store model metadata as variables
            await self.session_context.register_variable(
                "current_model", "string", model_id
            )
            
        return {
            "model_id": model_id,
            "model_type": model_type,
            "training_complete": True
        }

# Usage in grpc_server.py or your bridge
adapter = DataScienceAdapter()
```

### Simple Command Handler Pattern

For simpler use cases without session management:

```python
# my_simple_adapter.py
from snakepit_bridge import BaseCommandHandler, ProtocolHandler
from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression

class MySimpleHandler(BaseCommandHandler):
    def _register_commands(self):
        self.register_command("uppercase", self.handle_uppercase)
        self.register_command("word_count", self.handle_word_count)
    
    def handle_uppercase(self, args):
        text = args.get("text", "")
        return {"result": text.upper()}
    
    def handle_word_count(self, args):
        text = args.get("text", "")
        words = text.split()
        return {
            "word_count": len(words),
            "char_count": len(text),
            "unique_words": len(set(words))
        }

def main():
    setup_broken_pipe_suppression()
    
    command_handler = MySimpleHandler()
    protocol_handler = ProtocolHandler(command_handler)
    setup_graceful_shutdown(protocol_handler)
    
    protocol_handler.run()

if __name__ == "__main__":
    main()
```

#### Key Benefits of V2 Approach
- ✅ **No sys.path manipulation** - proper package imports
- ✅ **Location independent** - works from any directory  
- ✅ **Production ready** - can be packaged and installed
- ✅ **Enhanced error handling** - robust shutdown and signal management
- ✅ **Type checking** - full IDE support with proper imports

### Elixir Adapter Implementation

```elixir
defmodule MyApp.RubyAdapter do
  @behaviour Snakepit.Adapter
  
  @impl true
  def executable_path do
    System.find_executable("ruby")
  end
  
  @impl true
  def script_path do
    Path.join(:code.priv_dir(:my_app), "ruby/bridge.rb")
  end
  
  @impl true
  def script_args do
    ["--mode", "pool-worker"]
  end
  
  @impl true
  def supported_commands do
    ["ping", "process_data", "generate_report"]
  end
  
  @impl true
  def validate_command("process_data", args) do
    if Map.has_key?(args, :data) do
      :ok
    else
      {:error, "Missing required field: data"}
    end
  end
  
  def validate_command("ping", _args), do: :ok
  def validate_command(cmd, _args), do: {:error, "Unsupported command: #{cmd}"}
  
  # Optional callbacks
  @impl true
  def prepare_args("process_data", args) do
    # Transform args before sending
    Map.update(args, :data, "", &String.trim/1)
  end
  
  @impl true
  def process_response("generate_report", %{"report" => report} = response) do
    # Post-process the response
    {:ok, Map.put(response, "processed_at", DateTime.utc_now())}
  end
  
  @impl true
  def command_timeout("generate_report", _args), do: 120_000  # 2 minutes
  def command_timeout(_command, _args), do: 30_000  # Default 30 seconds
end
```

### External Bridge Script (Ruby Example)

```ruby
#!/usr/bin/env ruby
# priv/ruby/bridge.rb

require 'grpc'
require_relative 'snakepit_services_pb'

class BridgeHandler
  def initialize
    @commands = {
      'ping' => method(:handle_ping),
      'process_data' => method(:handle_process_data),
      'generate_report' => method(:handle_generate_report)
    }
  end
  
  def run
    STDERR.puts "Ruby bridge started"
    
    loop do
      # gRPC server handles request/response automatically
    end
  end
  
  private
  
  def process_command(request)
    command = request['command']
    args = request['args'] || {}
    
    handler = @commands[command]
    if handler
      result = handler.call(args)
      {
        'id' => request['id'],
        'success' => true,
        'result' => result,
        'timestamp' => Time.now.iso8601
      }
    else
      {
        'id' => request['id'],
        'success' => false,
        'error' => "Unknown command: #{command}",
        'timestamp' => Time.now.iso8601
      }
    end
  rescue => e
    {
      'id' => request['id'],
      'success' => false,
      'error' => e.message,
      'timestamp' => Time.now.iso8601
    }
  end
  
  def handle_ping(args)
    { 'status' => 'ok', 'message' => 'pong' }
  end
  
  def handle_process_data(args)
    data = args['data'] || ''
    { 'processed' => data.upcase, 'length' => data.length }
  end
  
  def handle_generate_report(args)
    # Simulate report generation
    sleep(1)
    { 
      'report' => {
        'title' => args['title'] || 'Report',
        'generated_at' => Time.now.iso8601,
        'data' => args['data'] || {}
      }
    }
  end
end

# Handle signals gracefully
Signal.trap('TERM') { exit(0) }
Signal.trap('INT') { exit(0) }

# Run the bridge
BridgeHandler.new.run
```

## 🗃️ Session Management

### Session Store API

```elixir
alias Snakepit.Bridge.SessionStore

# Create a session
{:ok, session} = SessionStore.create_session("session_123", ttl: 7200)

# Store data in session
:ok = SessionStore.store_program("session_123", "prog_1", %{
  model: "gpt-4",
  temperature: 0.8
})

# Retrieve session data
{:ok, session} = SessionStore.get_session("session_123")
{:ok, program} = SessionStore.get_program("session_123", "prog_1")

# Update session
{:ok, updated} = SessionStore.update_session("session_123", fn session ->
  Map.put(session, :last_activity, DateTime.utc_now())
end)

# Check if session exists
true = SessionStore.session_exists?("session_123")

# List all sessions
session_ids = SessionStore.list_sessions()

# Manual cleanup
SessionStore.delete_session("session_123")

# Get session statistics
stats = SessionStore.get_stats()
```

### Global Program Storage

```elixir
# Store programs accessible by any worker
:ok = SessionStore.store_global_program("template_1", %{
  type: "qa_template",
  prompt: "Answer the following question: {question}"
})

# Retrieve from any worker
{:ok, template} = SessionStore.get_global_program("template_1")
```

## 📊 Monitoring & Telemetry

### Available Events

```elixir
# Worker request completed
[:snakepit, :worker, :request]
# Measurements: %{duration: milliseconds}
# Metadata: %{result: :ok | :error}

# Worker initialized
[:snakepit, :worker, :initialized]
# Measurements: %{initialization_time: seconds}
# Metadata: %{worker_id: string}
```

### Setting Up Monitoring

```elixir
# In your application startup
:telemetry.attach_many(
  "snakepit-metrics",
  [
    [:snakepit, :worker, :request],
    [:snakepit, :worker, :initialized]
  ],
  &MyApp.Metrics.handle_event/4,
  %{}
)

defmodule MyApp.Metrics do
  require Logger
  
  def handle_event([:snakepit, :worker, :request], measurements, metadata, _config) do
    # Log slow requests
    if measurements.duration > 5000 do
      Logger.warning("Slow request: #{measurements.duration}ms")
    end
    
    # Send to StatsD/Prometheus/DataDog
    MyApp.Metrics.Client.histogram(
      "snakepit.request.duration",
      measurements.duration,
      tags: ["result:#{metadata.result}"]
    )
  end
  
  def handle_event([:snakepit, :worker, :initialized], measurements, metadata, _config) do
    Logger.info("Worker #{metadata.worker_id} started in #{measurements.initialization_time}s")
  end
end
```

### Pool Statistics

```elixir
stats = Snakepit.get_stats()
# Returns:
# %{
#   workers: 8,          # Total workers
#   available: 6,        # Available workers
#   busy: 2,            # Busy workers
#   requests: 1534,     # Total requests
#   queued: 0,          # Currently queued
#   errors: 12,         # Total errors
#   queue_timeouts: 3,  # Queue timeout count
#   pool_saturated: 0   # Saturation rejections
# }
```

## 🏗️ Architecture Deep Dive

### Component Overview


```
┌───────────────────────────────────────────────────────┐
│                    Snakepit Application               │
├───────────────────────────────────────────────────────┤
│                                                       │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │    Pool     │  │ SessionStore │  │ProcessRegistry│ │
│  │  Manager    │  │   (ETS)      │  │ (ETS + DETS) │ │
│  └──────┬──────┘  └──────────────┘  └───────────────┘ │
│         │                                             │
│  ┌──────▼────────────────────────────────────────────┐│
│  │            WorkerSupervisor (Dynamic)             ││
│  └──────┬────────────────────────────────────────────┘│
│         │                                             │
│  ┌──────▼──────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Worker    │  │   Worker     │  │   Worker     │  │
│  │  Starter    │  │  Starter     │  │  Starter     │  │
│  │(Supervisor) │  │(Supervisor)  │  │(Supervisor)  │  │
│  └──────┬──────┘  └───────┬──────┘  └───────┬──────┘  │
│         │                 │                 │         │
│  ┌──────▼──────┐  ┌───────▼──────┐  ┌───────▼──────┐  │
│  │   Worker    │  │   Worker     │  │   Worker     │  │
│  │ (GenServer) │  │ (GenServer)  │  │ (GenServer)  │  │
│  └──────┬──────┘  └───────┬──────┘  └───────┬──────┘  │
│         │                 │                 │         │
└─────────┼─────────────────┼─────────────────┼─────────┘
          │                 │                 │
    ┌─────▼──────┐    ┌─────▼──────┐    ┌─────▼──────┐
    │  External  │    │  External  │    │  External  │
    │  Process   │    │  Process   │    │  Process   │
    │  (Python)  │    │  (Node.js) │    │   (Ruby)   │
    └────────────┘    └────────────┘    └────────────┘
```

### Key Design Decisions

1. **Concurrent Initialization**: Workers start in parallel using `Task.async_stream`
2. **Permanent Wrapper Pattern**: Worker.Starter supervises Workers for auto-restart
3. **Centralized State**: All session data in ETS, workers are stateless
4. **Registry-Based**: O(1) worker lookups and reverse PID lookups
5. **gRPC Communication**: HTTP/2 protocol with streaming support
6. **Persistent Process Tracking**: ProcessRegistry uses DETS for crash-resistant tracking

### Process Lifecycle

1. **Startup**:
   - Pool manager starts
   - Concurrently spawns N workers via WorkerSupervisor
   - Each worker starts its external process
   - Workers send init ping and register when ready

2. **Request Flow**:
   - Client calls `Snakepit.execute/3`
   - Pool finds available worker (with session affinity if applicable)
   - Worker sends request to external process
   - External process responds
   - Worker returns result to client

3. **Crash Recovery**:
   - Worker crashes → Worker.Starter restarts it automatically
   - External process dies → Worker detects and crashes → restart
   - Pool crashes → Supervisor restarts entire pool
   - BEAM crashes → ProcessRegistry cleans orphans on next startup

4. **Shutdown**:
   - Pool manager sends shutdown to all workers
   - Workers close ports gracefully (SIGTERM)
   - ApplicationCleanup ensures no orphaned processes (SIGKILL)

## ⚡ Performance

### gRPC Performance Benchmarks

```
Configuration: 16 workers, gRPC Python adapter
Hardware: 8-core CPU, 32GB RAM

gRPC Performance:

Startup Time:
- Sequential: 16 seconds (1s per worker)
- Concurrent: 1.2 seconds (13x faster)

Throughput (gRPC Non-Streaming):
- Simple computation: 75,000 req/s
- ML inference: 12,000 req/s
- Session operations: 68,000 req/s

Latency (p99, gRPC):
- Simple computation: < 1.2ms
- ML inference: < 8ms
- Session operations: < 0.6ms

Streaming Performance:
- Throughput: 250,000 chunks/s
- Memory usage: Constant (streaming)
- First chunk latency: < 5ms

Connection overhead:
- Initial connection: 15ms
- Reconnection: 8ms
- Health check: < 1ms
```

### Optimization Tips

1. **Pool Size**: Start with `System.schedulers_online() * 2`
2. **Queue Size**: Monitor `pool_saturated` errors and adjust
3. **Timeouts**: Set appropriate timeouts per command type
4. **Session TTL**: Balance memory usage vs cache hits
5. **Health Checks**: Increase interval for stable workloads

## 🚀 Binary Serialization

### Overview

Snakepit v0.3+ includes automatic binary serialization for large data transfers, providing significant performance improvements for ML/AI workloads that involve tensors, embeddings, and other numerical arrays.

### How It Works

1. **Automatic Detection**: When variable data exceeds 10KB, Snakepit automatically switches from JSON to binary encoding
2. **Type Support**: Currently optimized for `tensor` and `embedding` variable types
3. **Zero Configuration**: No code changes required - it just works
4. **Protocol**: Uses Erlang's native binary format (ETF) on Elixir side and Python's pickle on Python side

### Performance Benefits

```elixir
# Example: 1000x1000 tensor (8MB of float data)
# JSON encoding: ~500ms
# Binary encoding: ~50ms (10x faster!)

# Create a large tensor
{:ok, _} = Snakepit.execute_in_session("ml_session", "create_tensor", %{
  shape: [1000, 1000],
  fill_value: 0.5
})

# The tensor is automatically stored using binary serialization
# Retrieval is also optimized
{:ok, tensor} = Snakepit.execute_in_session("ml_session", "get_variable", %{
  name: "large_tensor"
})
```

### Size Threshold

The 10KB threshold (10,240 bytes) is optimized for typical workloads:
- **Below 10KB**: JSON encoding (better for debugging, human-readable)
- **Above 10KB**: Binary encoding (better for performance)

### Python Usage

```python
# In your Python adapter
from snakepit_bridge import SessionContext

class MLAdapter:
    def process_embeddings(self, ctx: SessionContext, batch_size: int):
        # Generate large embeddings (e.g., 512-dimensional)
        embeddings = np.random.randn(batch_size, 512).tolist()
        
        # This automatically uses binary serialization if > 10KB
        ctx.register_variable("batch_embeddings", "embedding", embeddings)
        
        # Retrieval also handles binary data transparently
        stored = ctx["batch_embeddings"]
        return {"shape": [len(stored), len(stored[0])]}
```

### Technical Details

#### Binary Format Specification

1. **Tensor Type**:
   - Metadata (JSON): `{"shape": [dims...], "dtype": "float32", "binary_format": "pickle/erlang_binary"}`
   - Binary data: Serialized flat array of values

2. **Embedding Type**:
   - Metadata (JSON): `{"shape": [length], "dtype": "float32", "binary_format": "pickle/erlang_binary"}`
   - Binary data: Serialized array of float values

#### Protocol Buffer Changes

The following fields support binary data:
- `Variable.binary_value`: Stores large variable data
- `SetVariableRequest.binary_value`: Sets variable with binary data
- `RegisterVariableRequest.initial_binary_value`: Initial binary value
- `BatchSetVariablesRequest.binary_updates`: Batch binary updates
- `ExecuteToolRequest.binary_parameters`: Binary tool parameters

### Best Practices

1. **Variable Types**: Always use proper types (`tensor`, `embedding`) for large numerical data
2. **Batch Operations**: Use batch updates for multiple large variables to minimize overhead
3. **Memory Management**: Binary data is held in memory - monitor usage for very large datasets
4. **Compatibility**: Binary format is internal - use standard types when sharing data externally

### Limitations

1. **Type Support**: Currently only `tensor` and `embedding` types use binary serialization
2. **Format Lock-in**: Binary data uses platform-specific formats (ETF/pickle)
3. **Debugging**: Binary data is not human-readable in logs/inspection

## 🔧 Troubleshooting

### Common Issues

#### Orphaned Python Processes

```elixir
# Check for orphaned processes
ps aux | grep grpc_server.py

# Verify ProcessRegistry is cleaning up
Snakepit.Pool.ProcessRegistry.get_stats()

# Check DETS file location
ls -la priv/data/process_registry.dets

# See detailed documentation
# README_PROCESS_MANAGEMENT.md
```

#### Workers Not Starting

```elixir
# Check adapter configuration
adapter = Application.get_env(:snakepit, :adapter_module)
adapter.executable_path()  # Should return valid path
File.exists?(adapter.script_path())  # Should return true

# Check logs for errors
Logger.configure(level: :debug)
```

#### Port Exits

```elixir
# Enable port tracing
:erlang.trace(Process.whereis(Snakepit.Pool.Worker), true, [:receive, :send])

# Check external process logs
# Python: Add logging to bridge script
# Node.js: Check stderr output
```

#### Memory Leaks

```elixir
# Monitor ETS usage
:ets.info(:snakepit_sessions, :memory)

# Check for orphaned processes
Snakepit.Pool.ProcessRegistry.get_stats()

# Force cleanup
Snakepit.Bridge.SessionStore.cleanup_expired_sessions()
```

### Debug Mode

```elixir
# Enable debug logging
Logger.configure(level: :debug)

# Trace specific worker
:sys.trace(Snakepit.Pool.Registry.via_tuple("worker_1"), true)

# Get internal state
:sys.get_state(Snakepit.Pool)
```

## 📚 Additional Documentation

- [Testing Guide](README_TESTING.md) - How to run and write tests  
- [Unified gRPC Bridge](README_UNIFIED_GRPC_BRIDGE.md) - Stage 0, 1, and 2 implementation details
- [Bidirectional Tool Bridge](README_BIDIRECTIONAL_TOOL_BRIDGE.md) - Cross-language function execution between Elixir and Python
- [Process Management](README_PROCESS_MANAGEMENT.md) - Persistent tracking and orphan cleanup
- [gRPC Communication](README_GRPC.md) - Streaming and non-streaming gRPC details
- Python Bridge Implementations - See sections above for V1, V2, Enhanced, and gRPC bridges

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](https://github.com/nshkrdotcom/snakepit/blob/main/CONTRIBUTING.md) for details.

### Development Setup

```bash
# Clone the repo
git clone https://github.com/nshkrdotcom/snakepit.git
cd snakepit

# Install dependencies
mix deps.get

# Run tests
mix test

# Run example scripts
elixir examples/v2/session_based_demo.exs
elixir examples/javascript_grpc_demo.exs

# Check code quality
mix format --check-formatted
mix dialyzer
```

### Running Tests

```bash
# All tests
mix test

# With coverage
mix test --cover

# Specific test
mix test test/snakepit_test.exs:42
```

## 📝 License

Snakepit is released under the MIT License. See the [LICENSE](https://github.com/nshkrdotcom/snakepit/blob/main/LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the need for reliable ML/AI integrations in Elixir
- Built on battle-tested OTP principles
- Special thanks to the Elixir community

## 📊 Development Status

**v0.3 (Current Release)**
- ✅ **gRPC streaming bridge** implementation complete
- ✅ **Unified gRPC architecture** for all communication
- ✅ **Python Bridge V2** architecture with production packaging
- ✅ **Comprehensive documentation** and examples
- ✅ **Performance benchmarks** and optimization
- ✅ **End-to-end testing** across all protocols

**Roadmap**
- 🔄 Enhanced streaming operations and cancellation
- 🔄 Additional language adapters (Ruby, R, Go)
- 🔄 Advanced telemetry and monitoring features
- 🔄 Distributed worker pools

## 📚 Resources

- [Hex Package](https://hex.pm/packages/snakepit)
- [API Documentation](https://hexdocs.pm/snakepit)
- [GitHub Repository](https://github.com/nshkrdotcom/snakepit)
- [Example Projects](https://github.com/nshkrdotcom/snakepit/tree/main/examples)
- [gRPC Bridge Documentation](README_GRPC.md)
- Python Bridge Documentation - See sections above

---

Made with ❤️ by [NSHkr](https://github.com/nshkrdotcom)
