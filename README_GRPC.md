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

### Connection lifecycle & channel reuse

- Workers store the OS-negotiated port after `GRPC_READY`, so registry lookups always return the live endpoint even when the adapter requested port `0`.
- `BridgeServer` first asks the worker for its already-open `GRPC.Stub` and only dials a new channel as a fallback—cutting handshake latency and ensuring sockets are torn down after use.
- Tests: `test/unit/grpc/grpc_worker_ephemeral_port_test.exs` (port persistence) and `test/snakepit/grpc/bridge_server_test.exs` (channel reuse) guard the behaviour.

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

### State protection & quotas

- SessionStore, ToolRegistry, and ProcessRegistry expose their state through `:protected` ETS tables and keep DETS handles private, so only the owning processes can mutate core metadata.
- Configurable session/program quotas return tagged errors such as `{:error, :session_quota_exceeded}` or `{:error, {:program_quota_exceeded, session_id}}`, making it easy to surface actionable messages to callers.
- Regression coverage: `test/unit/bridge/session_store_test.exs` exercises quota paths, while `test/unit/pool/process_registry_security_test.exs` ensures ETS/DETS access stays locked down.

### Logging redaction & diagnostics

- \Snakepit.Logger.Redaction (internal helper) now collapses sensitive payloads into short summaries before anything hits the log pipeline, preventing credential or large blob leaks during gRPC debugging.
- Bridge telemetry ties the redaction summaries to execution spans so you still get useful context without sacrificing safety.
- Guarded by `test/unit/logger/redaction_test.exs`, which asserts both redaction coverage and fallback behaviour.

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

#### Streaming chunk envelope

- Each callback receives a map built from `ToolChunk`: decoded JSON payload merged with `"is_final"` and optional `_metadata`.
- Binary responses degrade gracefully to `"raw_data_base64"` so consumers can still inspect results without guessing encodings.
- Regression coverage: `test/snakepit/streaming_regression_test.exs` asserts ordering/finality while Python fixtures cover metadata propagation.

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

> **Invalid payloads**: When a tool parameter is encoded as malformed JSON the bridge returns `{:error, {:invalid_parameter, key, message}}` before contacting the worker. See `test/snakepit/grpc/bridge_server_test.exs` for real examples.

## Streaming Examples

### Quick Demo

Run the end-to-end streaming example to watch five progress updates stream from Python back into Elixir:

```bash
MIX_ENV=dev mix run examples/stream_progress_demo.exs
```

Internally it calls the `stream_progress` tool with a configurable `delay_ms`
so you can watch each chunk arrive roughly every 750 ms. Chunks look like:

```elixir
%{
  "is_final" => boolean(),
  "message" => String.t(),
  "progress" => float(),
  "step" => pos_integer(),
  "total" => pos_integer()
}
```

`"is_final"` is set on the last chunk so you can detect completion without relying on timeouts.

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

### Binary Serialization Performance

gRPC mode includes automatic binary serialization for large data:

| Data Size | JSON Encoding | Binary Encoding | Speedup |
|-----------|--------------|-----------------|---------|
| 1KB | 0.1ms | 0.1ms | 1x (uses JSON) |
| 10KB | 2ms | 2ms | 1x (threshold) |
| 100KB | 25ms | 3ms | **8x faster** |
| 1MB | 300ms | 30ms | **10x faster** |
| 10MB | 3500ms | 250ms | **14x faster** |

The 10KB threshold ensures optimal performance:
- Small data remains human-readable (JSON)
- Large data gets maximum performance (binary)

#### Binary Tool Parameters

`ExecuteToolRequest` also exposes a `binary_parameters` map for payloads that should never be JSON encoded (for example, pickled tensors or zipped archives). When a client sends both maps:

- The Elixir bridge decodes the regular `parameters` map as before.
- Binary entries show up in local Elixir tools as `{:binary, payload}` so handlers can pattern-match without guessing.
- Remote executions forward the **original** binary map to Python workers via gRPC. The helper `Snakepit.GRPC.Client.execute_tool/5` accepts `binary_parameters: %{ "blob" => <<...>> }` in the options list to make this explicit.
- Supplying a non-binary value (such as an integer or map) will raise an `invalid_binary_parameter` error before the request reaches any tool, preventing silent truncation.

Keep binary keys distinct from JSON keys to avoid confusion, and continue to prefer JSON for human-readable inputs.

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

## Creating Streaming Commands in Python

This section shows how to implement custom streaming commands in your Python adapters.

### Basic Streaming Command

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    @tool(description="Stream progress updates", supports_streaming=True)
    def progress_stream(self, count: int = 10, delay: float = 0.5):
        """
        Stream progress updates to the client.

        For streaming tools, return a generator that yields dictionaries.
        Each yielded dict becomes a chunk sent to the Elixir callback.
        """
        import time

        for i in range(count):
            # Yield progress chunk
            yield {
                "progress": i + 1,
                "total": count,
                "percent": ((i + 1) / count) * 100,
                "message": f"Processing item {i + 1} of {count}",
                "is_final": False
            }
            time.sleep(delay)

        # Final chunk
        yield {
            "is_final": True,
            "total_processed": count,
            "message": "Stream complete"
        }
```

### ML Batch Inference Streaming

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool
import time

class MLAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        # Load your model here
        self.model = self._load_model()

    @tool(description="Batch inference with streaming results", supports_streaming=True)
    def batch_inference(self, items: list, model_path: str = None):
        """
        Process items in a batch, streaming each result as it completes.
        """
        total = len(items)

        for idx, item in enumerate(items):
            # Perform inference
            prediction, confidence = self._predict(item)

            # Yield result for this item
            yield {
                "item": item,
                "index": idx,
                "prediction": prediction,
                "confidence": confidence,
                "progress": idx + 1,
                "total": total,
                "is_final": False
            }

        # Final summary
        yield {
            "is_final": True,
            "total_processed": total,
            "message": f"Processed {total} items successfully"
        }

    def _predict(self, item):
        # Your ML inference logic here
        # This is a placeholder
        time.sleep(0.1)
        return "predicted_class", 0.95

    def _load_model(self):
        # Load your model
        return None
```

### Large Dataset Processing

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool
import pandas as pd

class DataAdapter(BaseAdapter):
    @tool(description="Process large datasets with progress", supports_streaming=True)
    def process_large_dataset(self, file_path: str, chunk_size: int = 10000):
        """
        Process a large CSV file in chunks, streaming progress.
        """
        # Get total rows (for progress calculation)
        total_rows = sum(1 for _ in open(file_path)) - 1  # -1 for header

        processed = 0
        errors = 0

        # Process in chunks
        for chunk in pd.read_csv(file_path, chunksize=chunk_size):
            # Process this chunk
            try:
                results = self._process_chunk(chunk)
                processed += len(chunk)

                # Yield progress
                yield {
                    "processed_rows": processed,
                    "total_rows": total_rows,
                    "progress_percent": (processed / total_rows) * 100,
                    "memory_usage_mb": chunk.memory_usage(deep=True).sum() / 1024 / 1024,
                    "is_final": False
                }
            except Exception as e:
                errors += 1
                yield {
                    "error": str(e),
                    "chunk_start": processed,
                    "is_final": False
                }

        # Final statistics
        yield {
            "is_final": True,
            "final_stats": {
                "total_rows": total_rows,
                "processed": processed,
                "errors": errors,
                "skipped": total_rows - processed
            }
        }

    def _process_chunk(self, chunk):
        # Your processing logic
        return chunk.apply(lambda row: row, axis=1)
```

### Real-time Log Analysis

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool
import re
import time

class LogAdapter(BaseAdapter):
    @tool(description="Tail and analyze logs in real-time", supports_streaming=True)
    def tail_and_analyze(self, log_path: str, patterns: list, context_lines: int = 3):
        """
        Stream log analysis results in real-time.
        """
        pattern_regexes = [re.compile(p) for p in patterns]

        # Simulate tailing (in production, use actual file watching)
        with open(log_path, 'r') as f:
            for line_num, line in enumerate(f):
                for pattern_idx, regex in enumerate(pattern_regexes):
                    if regex.search(line):
                        # Found a match
                        severity = self._determine_severity(line)

                        yield {
                            "line_number": line_num,
                            "log_line": line.strip(),
                            "pattern_matched": patterns[pattern_idx],
                            "severity": severity,
                            "timestamp": self._extract_timestamp(line),
                            "is_final": False
                        }

                # Simulate real-time (remove for actual file watching)
                time.sleep(0.01)

        yield {
            "is_final": True,
            "message": "Log analysis complete"
        }

    def _determine_severity(self, line):
        if "FATAL" in line or "CRITICAL" in line:
            return "FATAL"
        elif "ERROR" in line:
            return "ERROR"
        elif "WARN" in line:
            return "WARN"
        return "INFO"

    def _extract_timestamp(self, line):
        # Extract timestamp from log line
        # This is a placeholder
        return "2025-01-20T15:30:45"
```

### ML Training with Epoch Updates

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool
import time

class TrainingAdapter(BaseAdapter):
    @tool(description="Train model with streaming epoch updates", supports_streaming=True)
    def distributed_training(self, model_config: dict, training_config: dict, dataset_path: str):
        """
        Train a model and stream updates for each epoch.
        """
        epochs = training_config.get("epochs", 100)
        best_val_acc = 0.0

        for epoch in range(1, epochs + 1):
            # Simulate training epoch
            train_loss, train_acc = self._train_epoch(epoch)
            val_loss, val_acc = self._validate_epoch(epoch)

            # Track best accuracy
            if val_acc > best_val_acc:
                best_val_acc = val_acc
                model_path = f"/models/model_epoch_{epoch}.pkl"
                self._save_checkpoint(model_path)

            # Yield epoch results
            yield {
                "epoch": epoch,
                "total_epochs": epochs,
                "train_loss": train_loss,
                "train_acc": train_acc,
                "val_loss": val_loss,
                "val_acc": val_acc,
                "learning_rate": self._get_current_lr(epoch),
                "is_final": False
            }

        # Final result
        yield {
            "is_final": True,
            "final_model_path": model_path,
            "best_val_accuracy": best_val_acc,
            "total_epochs": epochs,
            "message": "Training complete"
        }

    def _train_epoch(self, epoch):
        # Training logic (placeholder)
        time.sleep(0.1)
        return 2.5 - (epoch * 0.02), 0.1 + (epoch * 0.008)

    def _validate_epoch(self, epoch):
        # Validation logic (placeholder)
        time.sleep(0.05)
        return 2.3 - (epoch * 0.018), 0.15 + (epoch * 0.007)

    def _get_current_lr(self, epoch):
        # Learning rate schedule
        return 0.001 * (0.95 ** epoch)

    def _save_checkpoint(self, path):
        # Save model checkpoint
        pass
```

### Key Patterns for Streaming Commands

1. **Use Generator Functions**: Return a generator (using `yield`) instead of returning a value directly
2. **Mark with supports_streaming**: Add `supports_streaming=True` to the `@tool` decorator
3. **Include is_final**: Always include `"is_final": False` in intermediate chunks and `"is_final": True` in the final chunk
4. **Yield Dictionaries**: Each yielded value should be a dictionary that will be sent to the Elixir callback
5. **Progress Information**: Include progress indicators (`progress`, `total`, `percent`, etc.) to help users track completion
6. **Error Handling**: Yield error information as chunks rather than raising exceptions

### Calling Streaming Commands from Elixir

```elixir
# Call your custom streaming command
Snakepit.execute_stream("progress_stream", %{count: 10, delay: 0.5}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("✅ #{chunk["message"]}")
  else
    IO.puts("📊 Progress: #{chunk["percent"]}% - #{chunk["message"]}")
  end
end)

# With session affinity
Snakepit.execute_in_session_stream("ml_session", "distributed_training", %{
  model_config: %{layers: 12},
  training_config: %{epochs: 100},
  dataset_path: "/data/train.csv"
}, fn chunk ->
  if chunk["is_final"] do
    IO.puts("🎯 Training complete! Model: #{chunk["final_model_path"]}")
  else
    IO.puts("📈 Epoch #{chunk["epoch"]}: loss=#{chunk["train_loss"]}, acc=#{chunk["train_acc"]}")
  end
end)
```

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
