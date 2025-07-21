# Snakepit gRPC Streaming Guide

## Overview

This guide covers Snakepit's gRPC streaming implementation - a modern replacement for stdin/stdout communication that enables real-time progress updates, progressive results, and superior performance for ML and data processing workflows.

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Core Concepts](#core-concepts)
- [API Reference](#api-reference)
- [Streaming Examples](#streaming-examples)
- [Performance](#performance)
- [Migration Guide](#migration-guide)
- [Troubleshooting](#troubleshooting)

## Quick Start

### 1. Install Dependencies

```bash
# Install gRPC dependencies
make install-grpc

# Generate protocol buffer code
make proto-python

# Verify installation
python -c "import grpc, snakepit_bridge.grpc.snakepit_pb2; print('✅ gRPC ready')"
```

### 2. Basic Configuration

```elixir
# Configure Snakepit with gRPC adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50051,
  port_range: 100  # Uses ports 50051-50151
})

{:ok, _} = Application.ensure_all_started(:snakepit)
```

### 3. Run Your First Stream

```elixir
# Traditional (still works)
{:ok, result} = Snakepit.execute("ping", %{})

# NEW: Streaming execution
Snakepit.execute_stream("ping_stream", %{count: 5}, fn chunk ->
  IO.puts("Received: #{chunk["message"]}")
end)
```

## Installation

### Prerequisites

- **Elixir**: 1.18+ with OTP 27+
- **Python**: 3.8+ 
- **System**: `protoc` compiler (for development)

### Elixir Dependencies

```elixir
# mix.exs
def deps do
  [
    {:grpc, "~> 0.8"},
    {:protobuf, "~> 0.12"},
    # ... existing deps
  ]
end
```

### Python Dependencies

```bash
# Option 1: Install with gRPC support
cd priv/python && pip install -e ".[grpc]"

# Option 2: Install manually
pip install grpcio>=1.50.0 protobuf>=4.0.0 grpcio-tools>=1.50.0

# Option 3: All features
pip install -e ".[all]"  # Includes gRPC + MessagePack
```

### Development Setup

```bash
# Complete development environment
make dev-setup

# Or step by step:
make install-grpc      # Install Python gRPC deps
make proto-python      # Generate protobuf code
make test             # Verify everything works
```

## Core Concepts

### Communication Protocols Comparison

| Protocol | Streaming | Multiplexing | Binary Data | Setup Complexity |
|----------|-----------|--------------|-------------|------------------|
| **stdin/stdout** | ❌ | ❌ | Base64 | Simple |
| **MessagePack** | ❌ | ❌ | ✅ Native | Simple |
| **gRPC** | ✅ Native | ✅ HTTP/2 | ✅ Native | Moderate |

### Protocol Selection

```elixir
# Snakepit automatically chooses the best available protocol:

# 1. If gRPC adapter configured and available → gRPC
# 2. If MessagePack adapter configured → MessagePack  
# 3. Fallback → JSON over stdin/stdout

# Force specific protocol:
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)        # gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonMsgpack)  # MessagePack
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)     # JSON
```

### Worker Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Elixir App    │    │  gRPC Worker    │    │ Python Process  │
│                 │◄──►│   (GenServer)   │◄──►│  (gRPC Server)  │
│ execute_stream  │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │              HTTP/2 Connection               │
         │                       │                       │
    Callback Handler      Connection Mgmt          Stream Handlers
```

### Session Management

```elixir
# Sessions work seamlessly with gRPC
session_id = "ml_training_#{user_id}"

# Session-based execution (maintains state)
{:ok, result} = Snakepit.execute_in_session(session_id, "initialize_model", model_config)

# Session-based streaming
Snakepit.execute_in_session_stream(session_id, "train_model", training_data, fn chunk ->
  IO.puts("Epoch #{chunk["epoch"]}: loss=#{chunk["loss"]}")
end)
```

## API Reference

### Basic Execution

```elixir
# Snakepit.execute/3 - Same as always
{:ok, result} = Snakepit.execute(command, args, timeout \\ 30_000)

# Examples
{:ok, _} = Snakepit.execute("ping", %{})
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})
```

### Streaming Execution

```elixir
# Snakepit.execute_stream/4 - NEW!
:ok = Snakepit.execute_stream(command, args, callback_fn, timeout \\ 300_000)

# Callback function receives each chunk
callback_fn = fn chunk ->
  if chunk["is_final"] do
    IO.puts("Stream complete!")
  else
    IO.puts("Progress: #{chunk["progress"]}%")
  end
end
```

### Session-based APIs

```elixir
# Session execution (existing)
{:ok, result} = Snakepit.execute_in_session(session_id, command, args, timeout \\ 30_000)

# Session streaming (NEW!)
:ok = Snakepit.execute_in_session_stream(session_id, command, args, callback_fn, timeout \\ 300_000)
```

### Error Handling

```elixir
case Snakepit.execute_stream("long_process", %{data: large_data}, callback) do
  :ok ->
    IO.puts("Stream completed successfully")
    
  {:error, :worker_timeout} ->
    IO.puts("Operation timed out")
    
  {:error, :grpc_unavailable} ->
    IO.puts("gRPC not available, check setup")
    
  {:error, reason} ->
    IO.puts("Stream failed: #{inspect(reason)}")
end
```

## Streaming Examples

### 1. ML Batch Inference

Stream inference results as each item completes:

```elixir
batch_items = ["image_001.jpg", "image_002.jpg", "image_003.jpg"]

Snakepit.execute_stream("batch_inference", %{
  model_path: "/models/resnet50.pkl",
  batch_items: batch_items
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("🎉 Batch inference complete!")
  else
    item = chunk["item"]
    prediction = chunk["prediction"] 
    confidence = chunk["confidence"]
    IO.puts("🧠 #{item}: #{prediction} (#{confidence}% confidence)")
  end
end)

# Output:
# 🧠 image_001.jpg: cat (94% confidence)
# 🧠 image_002.jpg: dog (87% confidence)  
# 🧠 image_003.jpg: bird (91% confidence)
# 🎉 Batch inference complete!
```

### 2. Large Dataset Processing

Process huge datasets with real-time progress:

```elixir
Snakepit.execute_stream("process_large_dataset", %{
  file_path: "/data/sales_data_10gb.csv",
  chunk_size: 10_000,
  operations: ["clean", "transform", "aggregate"]
}, fn chunk ->
  if chunk["is_final"] do
    stats = chunk["final_stats"]
    IO.puts("✅ Processing complete!")
    IO.puts("📊 Final stats: #{inspect(stats)}")
  else
    progress = chunk["progress_percent"]
    processed = chunk["processed_rows"]
    total = chunk["total_rows"]
    memory_mb = chunk["memory_usage_mb"]
    
    IO.puts("📊 Progress: #{progress}% (#{processed}/#{total} rows) - Memory: #{memory_mb}MB")
  end
end)

# Output:
# 📊 Progress: 10.0% (100000/1000000 rows) - Memory: 45MB
# 📊 Progress: 20.0% (200000/1000000 rows) - Memory: 47MB
# 📊 Progress: 30.0% (300000/1000000 rows) - Memory: 46MB
# ...
# ✅ Processing complete!
# 📊 Final stats: %{errors: 12, processed: 988000, skipped: 12}
```

### 3. Real-time Log Analysis

Analyze logs in real-time as new entries arrive:

```elixir
Snakepit.execute_stream("tail_and_analyze", %{
  log_path: "/var/log/app.log",
  patterns: ["ERROR", "FATAL", "OutOfMemoryError"],
  context_lines: 3
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("📊 Log analysis session ended")
  else
    severity = chunk["severity"]
    timestamp = chunk["timestamp"]
    line = chunk["log_line"]
    pattern = chunk["pattern_matched"]
    
    emoji = case severity do
      "FATAL" -> "💀"
      "ERROR" -> "🚨" 
      "WARN" -> "⚠️"
      _ -> "ℹ️"
    end
    
    IO.puts("#{emoji} [#{timestamp}] #{pattern}: #{String.slice(line, 0, 80)}...")
  end
end)

# Output:
# 🚨 [2025-01-20T15:30:45] ERROR: Database connection failed: timeout after 30s...
# ⚠️ [2025-01-20T15:30:50] WARN: High memory usage detected: 85% of heap used...
# 💀 [2025-01-20T15:31:00] FATAL: OutOfMemoryError: Java heap space exceeded...
```

### 4. Distributed Training Monitoring

Monitor ML training progress across multiple nodes:

```elixir
Snakepit.execute_stream("distributed_training", %{
  model_config: %{
    architecture: "transformer",
    layers: 24,
    hidden_size: 1024
  },
  training_config: %{
    epochs: 100,
    batch_size: 32,
    learning_rate: 0.001
  },
  dataset_path: "/data/training_set"
}, fn chunk ->
  if chunk["is_final"] do
    model_path = chunk["final_model_path"] 
    best_acc = chunk["best_val_accuracy"]
    IO.puts("🎯 Training complete! Best accuracy: #{best_acc}")
    IO.puts("💾 Model saved: #{model_path}")
  else
    epoch = chunk["epoch"]
    train_loss = chunk["train_loss"]
    val_loss = chunk["val_loss"] 
    train_acc = chunk["train_acc"]
    val_acc = chunk["val_acc"]
    lr = chunk["learning_rate"]
    
    IO.puts("📈 Epoch #{epoch}/100:")
    IO.puts("   Train: loss=#{train_loss}, acc=#{train_acc}")
    IO.puts("   Val:   loss=#{val_loss}, acc=#{val_acc}")
    IO.puts("   LR: #{lr}")
  end
end)

# Output:
# 📈 Epoch 1/100:
#    Train: loss=2.45, acc=0.12
#    Val:   loss=2.38, acc=0.15
#    LR: 0.001
# 📈 Epoch 2/100:
#    Train: loss=2.12, acc=0.23
#    Val:   loss=2.05, acc=0.28
#    LR: 0.001
# ...
# 🎯 Training complete! Best accuracy: 0.94
# 💾 Model saved: /models/transformer_best_20250120.pkl
```

### 5. Financial Data Pipeline

Process real-time financial data with technical analysis:

```elixir
Snakepit.execute_stream("realtime_stock_analysis", %{
  symbols: ["AAPL", "GOOGL", "MSFT", "TSLA"],
  indicators: ["RSI", "MACD", "SMA_20", "SMA_50"],
  alert_thresholds: %{
    rsi_oversold: 30,
    rsi_overbought: 70,
    volume_spike: 2.0
  }
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("📊 Market session ended")
  else
    symbol = chunk["symbol"]
    price = chunk["price"]
    volume = chunk["volume"] 
    rsi = chunk["rsi"]
    signal = chunk["trading_signal"]
    
    case signal do
      "BUY" -> IO.puts("🟢 #{symbol}: $#{price} - BUY signal (RSI: #{rsi})")
      "SELL" -> IO.puts("🔴 #{symbol}: $#{price} - SELL signal (RSI: #{rsi})")
      _ -> IO.puts("⚪ #{symbol}: $#{price} - HOLD (RSI: #{rsi})")
    end
  end
end)

# Output:
# ⚪ AAPL: $175.50 - HOLD (RSI: 45.2)
# 🟢 GOOGL: $142.80 - BUY signal (RSI: 28.5)
# ⚪ MSFT: $380.20 - HOLD (RSI: 52.1) 
# 🔴 TSLA: $210.15 - SELL signal (RSI: 73.8)
```

## Performance

### Streaming vs Traditional Comparison

| Metric | stdin/stdout | MessagePack | gRPC Streaming |
|--------|-------------|-------------|----------------|
| **Latency (first result)** | 5-10s | 3-7s | **0.1-0.5s** |
| **Memory usage** | Grows with result | Grows with result | **Constant** |
| **Progress visibility** | None | None | **Real-time** |
| **Cancellation** | Kill process | Kill process | **Graceful** |
| **Error granularity** | End only | End only | **Per chunk** |
| **User experience** | "Is it working?" | "Is it working?" | **Live updates** |

### Benchmarks

```bash
# Large dataset processing (1GB CSV file)
Traditional: Submit → Wait 10 minutes → Get result or timeout
gRPC Stream: Submit → Progress every 30s → Complete with stats

# ML batch inference (1000 images)  
Traditional: Submit → Wait 5 minutes → Get all predictions
gRPC Stream: Submit → Get prediction 1 → Get prediction 2 → ...

# Real-time monitoring
Traditional: Not possible
gRPC Stream: Live tail of logs/metrics with analysis
```

### Memory Usage Patterns

```elixir
# Traditional: Memory grows with result size
results = []  # Starts empty
# ... processing 1GB of data ...
results = [huge_dataset_results]  # Now using 1GB+ memory

# gRPC Streaming: Constant memory usage
Snakepit.execute_stream("process_1gb_dataset", %{}, fn chunk ->
  process_chunk(chunk)  # Handle immediately
  # chunk gets garbage collected
end)
# Memory usage stays constant regardless of total data size
```

## Migration Guide

### From stdin/stdout to gRPC

**Step 1: Install gRPC**
```bash
make install-grpc
make proto-python
```

**Step 2: Update Configuration**
```elixir
# Before
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)

# After  
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_config, %{base_port: 50051, port_range: 100})
```

**Step 3: Keep Existing Code**
```elixir
# This still works exactly the same
{:ok, result} = Snakepit.execute("compute", %{operation: "add", a: 5, b: 3})
```

**Step 4: Add Streaming Where Beneficial**
```elixir
# Replace long-running operations with streaming versions
# Before: 
{:ok, results} = Snakepit.execute("batch_process", large_dataset)  # Blocks for minutes

# After:
Snakepit.execute_stream("batch_process", large_dataset, fn chunk ->
  update_progress_bar(chunk["progress"])
  save_partial_result(chunk["data"])
end)
```

### From MessagePack to gRPC

```elixir
# MessagePack config (keep as fallback)
Application.put_env(:snakepit, :adapters, [
  Snakepit.Adapters.GRPCPython,        # Try gRPC first
  Snakepit.Adapters.GenericPythonMsgpack  # Fallback to MessagePack
])
```

### Gradual Migration Strategy

1. **Phase 1**: Install gRPC alongside existing adapter
2. **Phase 2**: Test gRPC with non-critical workloads  
3. **Phase 3**: Move long-running operations to streaming
4. **Phase 4**: Default to gRPC, keep MessagePack as fallback
5. **Phase 5**: Full gRPC adoption

## Troubleshooting

### Common Issues

#### 1. "Generated gRPC code not found"

```bash
# Solution: Generate protobuf code
make proto-python

# Verify:
ls priv/python/snakepit_bridge/grpc/
# Should show: snakepit_pb2.py, snakepit_pb2_grpc.py
```

#### 2. "gRPC dependencies not available"

```bash
# Check Python dependencies
python -c "import grpc; print('gRPC:', grpc.__version__)"
python -c "import google.protobuf; print('Protobuf OK')"

# Install if missing
pip install 'snakepit-bridge[grpc]'
```

#### 3. "Port already in use"

```elixir
# Solution: Configure different port range
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50100,  # Try different base port
  port_range: 50     # Smaller range
})
```

#### 4. Worker initialization timeout

```bash
# Check Python process
ps aux | grep grpc_bridge

# Check Python errors
python priv/python/grpc_bridge.py --help

# Increase timeout
Application.put_env(:snakepit, :worker_init_timeout, 30_000)
```

#### 5. Streaming callback errors

```elixir
# Bad: Callback crashes on unexpected data
callback = fn chunk ->
  result = chunk["result"]  # May be nil
  process_result(result)    # Crashes if nil
end

# Good: Defensive callback
callback = fn chunk ->
  case chunk do
    %{"is_final" => true} ->
      IO.puts("Stream complete")
    %{"result" => result} when not is_nil(result) ->
      process_result(result)
    %{"error" => error} ->
      IO.puts("Stream error: #{error}")
    other ->
      IO.puts("Unexpected chunk: #{inspect(other)}")
  end
end
```

### Debug Mode

```elixir
# Enable debug logging
Logger.configure(level: :debug)

# Trace gRPC worker
:sys.trace(worker_pid, true)

# Check gRPC connection health
Snakepit.GRPCWorker.get_health(worker)
Snakepit.GRPCWorker.get_info(worker)
```

### Performance Tuning

```elixir
# Adjust gRPC settings
Application.put_env(:snakepit, :grpc_config, %{
  base_port: 50051,
  port_range: 100,
  # Increase concurrent streams
  max_concurrent_streams: 10,
  # Tune timeouts
  connection_timeout: 10_000,
  stream_timeout: 300_000
})

# Pool optimization
Application.put_env(:snakepit, :pool_config, %{
  pool_size: 16,  # More workers for concurrent streams
  worker_init_timeout: 30_000
})
```

### Fallback Strategy

```elixir
# Graceful degradation if gRPC unavailable
defmodule MyApp.SnakepitClient do
  def execute_with_fallback(command, args, opts \\ []) do
    case Snakepit.execute(command, args, opts) do
      {:ok, result} -> 
        {:ok, result}
      {:error, :grpc_unavailable} ->
        # Fallback to MessagePack
        with_adapter(Snakepit.Adapters.GenericPythonMsgpack, fn ->
          Snakepit.execute(command, args, opts)
        end)
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp with_adapter(adapter, fun) do
    old_adapter = Application.get_env(:snakepit, :adapter_module)
    Application.put_env(:snakepit, :adapter_module, adapter)
    
    try do
      fun.()
    after
      Application.put_env(:snakepit, :adapter_module, old_adapter)
    end
  end
end
```

---