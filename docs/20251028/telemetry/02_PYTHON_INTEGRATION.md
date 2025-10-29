# Python Telemetry Integration

**Date:** 2025-10-28
**Status:** Design Document

How Python workers emit telemetry that gets folded back into Elixir `:telemetry` events.

---

## Problem: Python → Elixir Telemetry Flow

Python workers need to emit telemetry, but:
1. Snakepit is an **Elixir library** - clients expect Elixir events
2. Python and Elixir run in **separate processes** (Port or gRPC)
3. No external dependencies allowed (no StatsD, Prometheus agents, etc.)
4. Must work with both **Process** and **Thread** modes

**Solution:** Python writes structured telemetry to stderr, Elixir captures and re-emits as `:telemetry` events.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ PYTHON WORKER PROCESS                                     │
│                                                            │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Your Python Code                                    │  │
│  │                                                      │  │
│  │  with telemetry.span("inference"):                 │  │
│  │      result = model.predict(data)                   │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                      │
│  ┌──────────────────▼───────────────────────────────────┐  │
│  │ snakepit_bridge/telemetry.py                        │  │
│  │                                                      │  │
│  │  sys.stderr.write('TELEMETRY:{json}\n')            │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                      │
│                stderr│                                      │
└─────────────────────┼──────────────────────────────────────┘
                      │
                      │ captured by Port/gRPC
                      │
┌─────────────────────▼──────────────────────────────────────┐
│ ELIXIR SNAKEPIT                                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Snakepit.Telemetry.PythonCapture                     │  │
│  │                                                       │  │
│  │  parse_telemetry_line(stderr_line)                   │  │
│  │  |> enrich_with_elixir_context(worker_context)       │  │
│  │  |> :telemetry.execute(...)                          │  │
│  └──────────────────┬────────────────────────────────────┘  │
│                     │                                       │
│       emits `:telemetry` events                             │
└─────────────────────┼───────────────────────────────────────┘
                      │
                      │
┌─────────────────────▼───────────────────────────────────────┐
│ CLIENT APPLICATION                                           │
│                                                               │
│  :telemetry.attach([:snakepit, :python, :call, :stop], ...) │
└──────────────────────────────────────────────────────────────┘
```

---

## Python Telemetry Emitter

### Simple API (snakepit_bridge/telemetry.py)

```python
"""
Telemetry emitter for Snakepit Python workers.

Writes structured telemetry to stderr which gets captured
and re-emitted by Elixir as :telemetry events.
"""
import sys
import json
import time
from contextlib import contextmanager
from typing import Dict, Any, Optional


class SnakepitTelemetry:
    """Zero-dependency telemetry emitter for Python side."""

    # Configuration (set by Elixir via environment or gRPC init)
    enabled = True
    sampling_rate = 1.0  # 0.0 to 1.0

    @staticmethod
    def emit(event_name: str,
             measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None) -> None:
        """
        Emit a telemetry event.

        Args:
            event_name: Event name like "inference.start" or "memory.sampled"
            measurements: Numeric data (duration, bytes, counts, etc.)
            metadata: Contextual data (model name, operation type, etc.)

        Example:
            telemetry.emit(
                "inference.start",
                {"system_time": time.time_ns()},
                {"model": "gpt-4", "operation": "predict"}
            )
        """
        if not SnakepitTelemetry.enabled:
            return

        # Sampling (for high-frequency events)
        import random
        if random.random() > SnakepitTelemetry.sampling_rate:
            return

        payload = {
            "event": event_name,
            "measurements": measurements or {},
            "metadata": metadata or {},
            "timestamp_ns": time.time_ns()
        }

        try:
            # Write to stderr as structured JSON
            # Format: TELEMETRY:{json}\n
            line = f"TELEMETRY:{json.dumps(payload)}\n"
            sys.stderr.write(line)
            sys.stderr.flush()
        except Exception:
            # Never crash the worker due to telemetry
            pass

    @staticmethod
    @contextmanager
    def span(operation: str, metadata: Optional[Dict[str, Any]] = None):
        """
        Context manager for timing operations.

        Automatically emits start, stop, and exception events.

        Example:
            with telemetry.span("inference", {"model": "gpt-4"}):
                result = model.predict(data)
        """
        meta = metadata or {}
        start_time = time.perf_counter_ns()

        # Emit start event
        SnakepitTelemetry.emit(
            f"{operation}.start",
            {"system_time": time.time_ns()},
            meta
        )

        try:
            yield

            # Success - emit stop event
            duration = time.perf_counter_ns() - start_time
            SnakepitTelemetry.emit(
                f"{operation}.stop",
                {
                    "duration": duration,
                    "system_time": time.time_ns()
                },
                {**meta, "result": "success"}
            )

        except Exception as e:
            # Exception - emit exception event
            duration = time.perf_counter_ns() - start_time
            SnakepitTelemetry.emit(
                f"{operation}.exception",
                {
                    "duration": duration,
                    "system_time": time.time_ns()
                },
                {
                    **meta,
                    "result": "error",
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
            )
            raise


# Convenience: module-level instance
telemetry = SnakepitTelemetry()
```

---

## Python Usage Examples

### Basic Instrumentation

```python
from snakepit_bridge.telemetry import telemetry

def execute_tool(tool_name: str, parameters: dict):
    """Execute a tool with telemetry."""

    # Manual start/stop
    telemetry.emit(
        "tool.execution.start",
        {"system_time": time.time_ns()},
        {"tool": tool_name, "param_count": len(parameters)}
    )

    try:
        result = actual_tool_execution(tool_name, parameters)

        telemetry.emit(
            "tool.execution.stop",
            {
                "duration": compute_duration(),
                "result_size": len(str(result))
            },
            {"tool": tool_name, "result": "success"}
        )

        return result
    except Exception as e:
        telemetry.emit(
            "tool.execution.exception",
            {"duration": compute_duration()},
            {
                "tool": tool_name,
                "error_type": type(e).__name__,
                "error": str(e)
            }
        )
        raise
```

### Using Spans (Recommended)

```python
from snakepit_bridge.telemetry import telemetry

def inference(model_name: str, input_data):
    """Run ML inference with automatic telemetry."""

    with telemetry.span("inference", {"model": model_name}):
        # Load model
        with telemetry.span("model.load", {"model": model_name}):
            model = load_model(model_name)

        # Preprocess
        with telemetry.span("preprocessing"):
            processed = preprocess(input_data)

        # Predict
        with telemetry.span("prediction", {"input_size": len(processed)}):
            result = model.predict(processed)

        # Emit custom metrics
        telemetry.emit(
            "inference.tokens",
            {"token_count": len(result.tokens)},
            {"model": model_name}
        )

        return result
```

### Memory Monitoring

```python
import psutil
from snakepit_bridge.telemetry import telemetry

def report_memory():
    """Report memory usage (called periodically by Elixir)."""
    process = psutil.Process()
    memory_info = process.memory_info()

    telemetry.emit(
        "memory.sampled",
        {
            "rss_bytes": memory_info.rss,
            "vms_bytes": memory_info.vms,
            "system_time": time.time_ns()
        },
        {"pid": process.pid}
    )
```

### GPU Metrics (PyTorch)

```python
import torch
from snakepit_bridge.telemetry import telemetry

def report_gpu_metrics():
    """Report GPU utilization."""
    if not torch.cuda.is_available():
        return

    for device_id in range(torch.cuda.device_count()):
        telemetry.emit(
            "gpu.sampled",
            {
                "memory_allocated": torch.cuda.memory_allocated(device_id),
                "memory_reserved": torch.cuda.memory_reserved(device_id),
                "utilization": torch.cuda.utilization(device_id),
                "system_time": time.time_ns()
            },
            {
                "device_id": device_id,
                "device_name": torch.cuda.get_device_name(device_id)
            }
        )
```

---

## Elixir Capture & Re-emit

### Capture Module (lib/snakepit/telemetry/python_capture.ex)

```elixir
defmodule Snakepit.Telemetry.PythonCapture do
  @moduledoc """
  Captures Python telemetry from stderr and re-emits as Elixir telemetry events.
  """

  require Logger

  @doc """
  Parse a line from Python stderr and emit telemetry if it's a telemetry line.

  Returns:
    - :ok if telemetry was emitted
    - :not_telemetry if line is not telemetry (should be logged normally)
    - {:error, reason} if parsing failed
  """
  def parse_and_emit(stderr_line, worker_context) do
    case parse_telemetry_line(stderr_line) do
      {:ok, event_name, measurements, metadata} ->
        emit_python_event(event_name, measurements, metadata, worker_context)
        :ok

      :not_telemetry ->
        :not_telemetry

      {:error, reason} = error ->
        Logger.debug("Failed to parse telemetry: #{inspect(reason)}")
        error
    end
  end

  # Parse the TELEMETRY:{json} format
  defp parse_telemetry_line("TELEMETRY:" <> json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"event" => event, "measurements" => m, "metadata" => meta}} ->
        {:ok, event, atomize_keys(m), atomize_keys(meta)}

      {:ok, %{"event" => event, "measurements" => m}} ->
        {:ok, event, atomize_keys(m), %{}}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp parse_telemetry_line(_), do: :not_telemetry

  # Convert Python event name to Elixir telemetry event name
  # "inference.start" -> [:snakepit, :python, :inference, :start]
  defp emit_python_event(event_name, measurements, python_metadata, worker_context) do
    event_parts = String.split(event_name, ".")
    event_name_atoms = [:snakepit, :python | Enum.map(event_parts, &String.to_atom/1)]

    # Enrich with Elixir context
    enriched_metadata =
      python_metadata
      |> Map.put(:node, node())
      |> Map.put(:worker_id, worker_context.worker_id)
      |> Map.put(:pool_name, worker_context.pool_name)
      |> Map.put(:python_pid, worker_context.python_pid)

    # Add correlation_id if present in worker context
    enriched_metadata =
      if worker_context[:correlation_id] do
        Map.put(enriched_metadata, :correlation_id, worker_context.correlation_id)
      else
        enriched_metadata
      end

    # Emit as Elixir telemetry event
    :telemetry.execute(event_name_atoms, measurements, enriched_metadata)
  end

  # Convert string keys to atoms (safely)
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {String.to_atom(key), value}
      {key, value} ->
        {key, value}
    end)
  end
  defp atomize_keys(value), do: value
end
```

### Integration with Worker (lib/snakepit/grpc_worker.ex)

```elixir
defmodule Snakepit.GRPCWorker do
  # ... existing code ...

  # When capturing stderr from Python process
  defp handle_python_stderr(line, state) do
    case Snakepit.Telemetry.PythonCapture.parse_and_emit(line, worker_context(state)) do
      :ok ->
        # Telemetry event emitted, don't log this line
        :ok

      :not_telemetry ->
        # Normal stderr, log it
        Logger.debug("[Python stderr] #{line}")

      {:error, reason} ->
        Logger.warning("Failed to parse telemetry: #{inspect(reason)}, line: #{line}")
    end
  end

  defp worker_context(state) do
    %{
      worker_id: state.worker_id,
      pool_name: state.pool_name,
      python_pid: state.python_pid,
      correlation_id: state.current_correlation_id  # if tracking per-request
    }
  end
end
```

---

## Configuration

### Elixir Side

```elixir
# config/config.exs
config :snakepit, :telemetry,
  python_telemetry: true,           # Capture Python telemetry
  python_sampling_rate: 1.0         # Forward to Python via env
```

### Python Side

Python configuration is passed via environment variables when spawning:

```elixir
# When starting Python worker
env = [
  {"SNAKEPIT_TELEMETRY_ENABLED", "true"},
  {"SNAKEPIT_TELEMETRY_SAMPLING_RATE", "0.25"}  # 25% sampling
]

Port.open({:spawn_executable, python_path}, [env: env, ...])
```

Python reads on startup:

```python
# snakepit_bridge/telemetry.py initialization
import os

SnakepitTelemetry.enabled = os.getenv("SNAKEPIT_TELEMETRY_ENABLED", "true").lower() == "true"
SnakepitTelemetry.sampling_rate = float(os.getenv("SNAKEPIT_TELEMETRY_SAMPLING_RATE", "1.0"))
```

---

## Event Flow Example

### Python emits:

```python
with telemetry.span("inference", {"model": "gpt-4"}):
    result = model.predict(data)
```

**Python writes to stderr:**
```
TELEMETRY:{"event":"inference.start","measurements":{"system_time":1698234567890},"metadata":{"model":"gpt-4"},"timestamp_ns":1698234567890123456}
TELEMETRY:{"event":"inference.stop","measurements":{"duration":123456789,"system_time":1698234580123},"metadata":{"model":"gpt-4","result":"success"},"timestamp_ns":1698234580123456789}
```

### Elixir captures and re-emits:

```elixir
:telemetry.execute(
  [:snakepit, :python, :inference, :start],
  %{system_time: 1698234567890},
  %{
    node: :"node1@localhost",
    worker_id: "worker_default_1",
    pool_name: :default,
    python_pid: 12345,
    model: "gpt-4"
  }
)

:telemetry.execute(
  [:snakepit, :python, :inference, :stop],
  %{duration: 123456789, system_time: 1698234580123},
  %{
    node: :"node1@localhost",
    worker_id: "worker_default_1",
    pool_name: :default,
    python_pid: 12345,
    model: "gpt-4",
    result: "success"
  }
)
```

### Client application receives:

```elixir
:telemetry.attach(
  "my-app-inference-tracker",
  [:snakepit, :python, :inference, :stop],
  fn _event, %{duration: duration}, %{model: model}, _config ->
    duration_ms = duration / 1_000_000
    Logger.info("Inference completed: #{model} in #{duration_ms}ms")
  end,
  nil
)
```

---

## Performance Considerations

### Stderr I/O Overhead

Writing to stderr is fast, but for extremely high-frequency events:

```python
# Sample high-frequency events
if random.random() < 0.1:  # 10% sampling
    telemetry.emit("high_frequency_event", ...)
```

Or configure via Elixir:

```elixir
config :snakepit, :telemetry,
  python_sampling_rate: 0.1  # 10%
```

### JSON Encoding Cost

Keep metadata small:

```python
# Good - small metadata
telemetry.emit("inference.start", {...}, {"model": "gpt-4"})

# Bad - large metadata
telemetry.emit("inference.start", {...}, {
    "model": "gpt-4",
    "full_prompt": huge_text,  # Don't send huge strings
    "all_parameters": {...}    # Don't send everything
})
```

### Async Emission (Future)

For Python 3.11+, could use async:

```python
async def emit_async(event, measurements, metadata):
    # Non-blocking telemetry
    await asyncio.to_thread(telemetry.emit, event, measurements, metadata)
```

---

## Testing

### Python Side

```python
# tests/test_telemetry.py
import sys
from io import StringIO
from snakepit_bridge.telemetry import telemetry

def test_telemetry_emit():
    # Capture stderr
    captured = StringIO()
    sys.stderr = captured

    telemetry.emit(
        "test.event",
        {"value": 42},
        {"key": "test"}
    )

    output = captured.getvalue()
    assert output.startswith("TELEMETRY:")

    # Parse JSON
    import json
    payload = json.loads(output.replace("TELEMETRY:", "").strip())
    assert payload["event"] == "test.event"
    assert payload["measurements"]["value"] == 42
```

### Elixir Side

```elixir
# test/snakepit/telemetry/python_capture_test.exs
defmodule Snakepit.Telemetry.PythonCaptureTest do
  use ExUnit.Case
  alias Snakepit.Telemetry.PythonCapture

  test "parses Python telemetry line" do
    line = ~s(TELEMETRY:{"event":"test.start","measurements":{"value":42},"metadata":{"key":"test"}})

    worker_context = %{
      worker_id: "test_worker",
      pool_name: :default,
      python_pid: 12345
    }

    # Attach test handler
    :telemetry.attach(
      "test-handler",
      [:snakepit, :python, :test, :start],
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    assert :ok = PythonCapture.parse_and_emit(line, worker_context)

    assert_receive {:telemetry,
      [:snakepit, :python, :test, :start],
      %{value: 42},
      metadata
    }

    assert metadata.worker_id == "test_worker"
    assert metadata.key == "test"
  end

  test "ignores non-telemetry lines" do
    line = "Regular Python output"
    assert :not_telemetry = PythonCapture.parse_and_emit(line, %{})
  end
end
```

---

## Best Practices

### DO:
- ✅ Use spans for timing operations
- ✅ Keep metadata small and relevant
- ✅ Sample high-frequency events
- ✅ Include correlation IDs for tracing
- ✅ Use descriptive event names (verb.noun pattern)

### DON'T:
- ❌ Send sensitive data in metadata (passwords, API keys)
- ❌ Send huge strings or data structures
- ❌ Emit telemetry in tight loops without sampling
- ❌ Crash on telemetry errors (always swallow exceptions)
- ❌ Use telemetry for logging (use logger for that)

---

**Next:** [03_CLIENT_GUIDE.md](./03_CLIENT_GUIDE.md) - How clients consume and extend telemetry
