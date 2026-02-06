# Streaming

Snakepit supports streaming execution for real-time progress updates, large data transfers, and continuous data streams.

## When to Use Streaming

- **Progress updates**: Long-running ML operations reporting incremental progress
- **Large data transfers**: Datasets too large for single responses
- **Real-time data**: Continuous sensor data, log streams, or live predictions
- **Batch processing**: Results delivered as items complete

For simple request-response patterns, use `Snakepit.execute/3` instead.

## Snakepit.execute_stream/4

```elixir
@spec execute_stream(command(), args(), callback_fn(), keyword()) ::
        :ok | {:error, Snakepit.Error.t()}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String.t()` | The streaming command |
| `args` | `map()` | Command arguments |
| `callback_fn` | `(term() -> any())` | Called for each chunk |
| `opts` | `keyword()` | Execution options |

| Option | Default | Description |
|--------|---------|-------------|
| `:pool` | `Snakepit.Pool` | Pool to use |
| `:timeout` | `300000` | Timeout in ms |
| `:session_id` | `nil` | Session affinity |
| `:affinity` | `nil` | Override affinity mode (`:hint`, `:strict_queue`, `:strict_fail_fast`) |

When using `:session_id` with strict affinity, streaming may return
`{:error, %Snakepit.Error{category: :pool, details: %{reason: :worker_busy}}}` or
`{:error, %Snakepit.Error{category: :pool, details: %{reason: :session_worker_unavailable}}}`
if the preferred worker is busy or unavailable.

### Basic Example

```elixir
:ok = Snakepit.execute_stream("process_items", %{items: list}, fn chunk ->
  IO.puts("Received: #{inspect(chunk)}")
end)
```

## Callback Function

The callback is invoked for each chunk, synchronously and in order.

```elixir
# Logging
callback = fn chunk -> IO.inspect(chunk) end

# Sending to another process
callback = fn chunk -> send(consumer_pid, {:chunk, chunk}) end
```

## Python Streaming Tools

### Enabling Streaming

Use `supports_streaming=True` in the `@tool` decorator:

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):

    @tool(description="Stream progress", supports_streaming=True)
    def stream_progress(self, steps: int = 10):
        for i in range(steps):
            yield {"step": i + 1, "total": steps, "progress": (i + 1) / steps * 100}
```

### Using Generators

Each `yield` becomes a chunk sent to Elixir:

```python
@tool(description="Stream numbers", supports_streaming=True)
def stream_numbers(self, count: int = 10):
    for i in range(count):
        yield {"number": i, "is_last": i == count - 1}
```

### StreamChunk Class

For explicit control over the final marker:

```python
from snakepit_bridge.adapters.showcase.tool import StreamChunk

@tool(description="Stream with metadata", supports_streaming=True)
def stream_items(self, count: int = 5):
    for i in range(count):
        yield StreamChunk(
            data={"index": i + 1, "value": f"Item {i + 1}"},
            is_final=(i == count - 1)
        )
```

## Progress Update Patterns

### Training Progress

```python
@tool(description="Train with progress", supports_streaming=True)
def train_model(self, epochs: int = 10):
    for epoch in range(epochs):
        loss = 1.0 / (epoch + 1)
        accuracy = min(0.95, 0.5 + epoch * 0.05)
        yield {"type": "progress", "epoch": epoch + 1, "loss": loss, "accuracy": accuracy}

    yield {"type": "complete", "final_loss": loss, "final_accuracy": accuracy}
```

Elixir consumer:

```elixir
:ok = Snakepit.execute_stream("train_model", %{epochs: 10}, fn chunk ->
  case chunk["type"] do
    "progress" -> IO.puts("Epoch #{chunk["epoch"]}: loss=#{chunk["loss"]}")
    "complete" -> IO.puts("Training complete!")
  end
end)
```

## Large Data Transfer Patterns

### Chunked Dataset

```python
@tool(description="Generate dataset", supports_streaming=True)
def generate_dataset(self, rows: int = 10000, chunk_size: int = 1000):
    import numpy as np
    total_sent = 0
    while total_sent < rows:
        batch = min(chunk_size, rows - total_sent)
        data = np.random.randn(batch, 10)
        total_sent += batch
        yield StreamChunk(
            data={"rows": batch, "total": total_sent, "data": data.tolist()},
            is_final=(total_sent >= rows)
        )
```

## Error Handling in Streams

### Python Errors

Exceptions propagate to Elixir:

```elixir
case Snakepit.execute_stream("may_fail", %{}, callback) do
  :ok -> IO.puts("Success")
  {:error, error} -> IO.puts("Failed: #{error.message}")
end
```

### Stream Cancellation

```elixir
task = Task.async(fn ->
  Snakepit.execute_stream("infinite_stream", %{}, fn chunk ->
    IO.puts("Received: #{inspect(chunk)}")
  end)
end)

Process.sleep(5000)
Task.shutdown(task, :brutal_kill)  # Cancel stream
```

## Complete Streaming Example

### Python Adapter

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool
from snakepit_bridge.adapters.showcase.tool import StreamChunk
import time

class MLStreamingAdapter(BaseAdapter):

    @tool(description="Train with streaming progress", supports_streaming=True)
    def train_with_progress(self, epochs: int = 10):
        loss, accuracy = 1.0, 0.5
        for epoch in range(epochs):
            time.sleep(0.5)
            loss *= 0.8
            accuracy = min(0.99, accuracy + 0.05)
            yield StreamChunk(
                data={"epoch": epoch + 1, "loss": round(loss, 4), "accuracy": round(accuracy, 4)},
                is_final=False
            )
        yield StreamChunk(
            data={"status": "complete", "model_id": f"model_{int(time.time())}"},
            is_final=True
        )
```

### Elixir Consumer

```elixir
defmodule MyApp.MLClient do
  require Logger

  def train_model(epochs) do
    Logger.info("Starting training")

    result = Snakepit.execute_stream("train_with_progress", %{epochs: epochs}, fn chunk ->
      if chunk["status"] == "complete" do
        Logger.info("Complete! Model: #{chunk["model_id"]}")
      else
        Logger.info("Epoch #{chunk["epoch"]}: loss=#{chunk["loss"]}, acc=#{chunk["accuracy"]}")
      end
    end)

    case result do
      :ok -> {:ok, "Training completed"}
      {:error, e} -> {:error, e}
    end
  end
end
```

## Performance Considerations

1. **Chunk size**: Balance responsiveness vs efficiency (1000-10000 items typical)
2. **Callback overhead**: Keep callbacks lightweight; offload heavy processing
3. **Timeouts**: Default is 5 minutes; adjust with `:timeout` option
4. **Memory**: Streaming reduces peak memory by processing incrementally
5. **gRPC required**: Streaming only works with gRPC adapters

## Server-Side Streaming Implementation

Snakepit's BridgeServer fully implements `ExecuteStreamingTool`,
enabling end-to-end gRPC streaming from external clients through to Python workers.

### Requirements for Streaming Tools

1. Tool must be a **remote** (Python) tool
2. Tool must have `supports_streaming: true` in metadata
3. Python adapter must implement the streaming tool as a generator

### Enabling a Tool for Streaming

In your Python adapter:

```python
@tool(description="Stream results", supports_streaming=True)
def my_streaming_tool(self, param: str):
    for i in range(10):
        yield {"step": i, "result": f"Processing {param}"}
```

The tool will be registered with streaming support automatically.

### Stream Chunk Metadata

Final chunks include automatic metadata decoration:
- `execution_time_ms`: Total execution time in milliseconds
- `tool_type`: The type of tool (always "remote" for streaming)
- `worker_id`: The ID of the worker that executed the tool

If the worker doesn't send a final chunk, Snakepit injects a synthetic final chunk
with `synthetic_final: "true"` in metadata.
