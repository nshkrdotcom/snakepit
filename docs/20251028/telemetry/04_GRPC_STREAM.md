# gRPC Telemetry Stream - Initial Implementation

**Date:** 2025-10-28
**Status:** Design Document - Phase 2.1

This is the **primary/initial implementation** for Python-to-Elixir telemetry folding.

---

## Why gRPC Stream?

✅ **Clean separation** - Telemetry stream separate from logs/data
✅ **Structured** - Protobuf messages, not JSON parsing
✅ **Bidirectional** - Can send control signals (sampling rate, enable/disable)
✅ **Efficient** - Binary protocol, no text parsing overhead
✅ **Already there** - Leverages existing gRPC infrastructure
✅ **Typed** - Schema-validated messages

---

## Protocol Design

### Protobuf Definitions

```protobuf
// snakepit_bridge.proto

// Telemetry service
service SnakepitBridge {
  // Existing RPCs...
  rpc ExecuteTool(...) returns (...);
  rpc ExecuteStreamingTool(...) returns (...);

  // NEW: Telemetry stream (bidirectional)
  rpc StreamTelemetry(stream TelemetryEvent) returns (stream TelemetryControl);
}

// Telemetry event from Python → Elixir
message TelemetryEvent {
  // Event name parts (e.g., ["inference", "start"])
  repeated string event_parts = 1;

  // Measurements (numeric data)
  map<string, TelemetryValue> measurements = 2;

  // Metadata (contextual information)
  map<string, string> metadata = 3;

  // Timestamp (nanoseconds since epoch)
  int64 timestamp_ns = 4;

  // Correlation ID for distributed tracing
  string correlation_id = 5;
}

// Flexible value type for measurements
message TelemetryValue {
  oneof value {
    int64 int_value = 1;
    double float_value = 2;
    string string_value = 3;
  }
}

// Control messages from Elixir → Python
message TelemetryControl {
  oneof control {
    TelemetrySamplingUpdate sampling = 1;
    TelemetryToggle toggle = 2;
    TelemetryEventFilter filter = 3;
  }
}

message TelemetrySamplingUpdate {
  double sampling_rate = 1;  // 0.0 to 1.0
  repeated string event_patterns = 2;  // Which events to sample
}

message TelemetryToggle {
  bool enabled = 1;
}

message TelemetryEventFilter {
  repeated string allowed_events = 1;   // Whitelist
  repeated string blocked_events = 2;   // Blacklist
}
```

---

## Python Implementation

### Telemetry Emitter (snakepit_bridge/telemetry.py)

```python
"""
gRPC-based telemetry emitter for Snakepit workers.
"""
import time
import asyncio
import random
from typing import Dict, Any, Optional, List
from contextlib import contextmanager
import grpc

from . import snakepit_bridge_pb2 as pb2


class GrpcTelemetryEmitter:
    """
    Emits telemetry events via gRPC stream.

    Maintains a background asyncio task that sends events to Elixir.
    """

    def __init__(self, telemetry_stub: Optional[Any] = None):
        self.stub = telemetry_stub
        self.enabled = True
        self.sampling_rate = 1.0
        self.event_queue = asyncio.Queue(maxsize=1000)
        self.stream_task = None

    async def start_stream(self):
        """Start the bidirectional telemetry stream."""
        if self.stub is None:
            return  # Telemetry not configured

        self.stream_task = asyncio.create_task(self._stream_loop())

    async def _stream_loop(self):
        """Main streaming loop - sends events, receives control."""
        try:
            async def event_generator():
                """Generate events from queue."""
                while True:
                    event = await self.event_queue.get()
                    if event is None:  # Shutdown signal
                        break
                    yield event

            # Bidirectional stream
            async for control in self.stub.StreamTelemetry(event_generator()):
                self._handle_control(control)

        except Exception as e:
            # Never crash the worker due to telemetry
            import sys
            print(f"Telemetry stream error: {e}", file=sys.stderr)

    def _handle_control(self, control: pb2.TelemetryControl):
        """Handle control messages from Elixir."""
        if control.HasField('sampling'):
            self.sampling_rate = control.sampling.sampling_rate

        elif control.HasField('toggle'):
            self.enabled = control.toggle.enabled

    def emit(self,
             event_name: str,
             measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """
        Emit a telemetry event.

        Args:
            event_name: Event name like "inference.start"
            measurements: Numeric data
            metadata: Context data
            correlation_id: For distributed tracing
        """
        if not self.enabled:
            return

        # Sampling
        if random.random() > self.sampling_rate:
            return

        # Build protobuf message
        event = pb2.TelemetryEvent(
            event_parts=event_name.split('.'),
            timestamp_ns=time.time_ns(),
            correlation_id=correlation_id or ""
        )

        # Convert measurements
        for key, value in (measurements or {}).items():
            if isinstance(value, int):
                event.measurements[key].int_value = value
            elif isinstance(value, float):
                event.measurements[key].float_value = value
            else:
                event.measurements[key].string_value = str(value)

        # Add metadata
        for key, value in (metadata or {}).items():
            event.metadata[key] = str(value)

        # Add to queue (non-blocking)
        try:
            self.event_queue.put_nowait(event)
        except asyncio.QueueFull:
            # Drop event if queue full (backpressure)
            pass

    @contextmanager
    def span(self, operation: str, metadata: Optional[Dict[str, Any]] = None):
        """Context manager for timing operations."""
        meta = metadata or {}
        start_time = time.perf_counter_ns()

        self.emit(
            f"{operation}.start",
            {"system_time": time.time_ns()},
            meta
        )

        try:
            yield

            duration = time.perf_counter_ns() - start_time
            self.emit(
                f"{operation}.stop",
                {"duration": duration, "system_time": time.time_ns()},
                {**meta, "result": "success"}
            )

        except Exception as e:
            duration = time.perf_counter_ns() - start_time
            self.emit(
                f"{operation}.exception",
                {"duration": duration, "system_time": time.time_ns()},
                {
                    **meta,
                    "result": "error",
                    "error_type": type(e).__name__,
                    "error_message": str(e)
                }
            )
            raise


# Global instance (initialized by bridge server)
_telemetry: Optional[GrpcTelemetryEmitter] = None

def initialize_telemetry(stub):
    """Initialize global telemetry instance."""
    global _telemetry
    _telemetry = GrpcTelemetryEmitter(stub)
    asyncio.create_task(_telemetry.start_stream())

def emit(event: str, measurements: Dict, metadata: Dict = None, correlation_id: str = None):
    """Convenience function for emitting telemetry."""
    if _telemetry:
        _telemetry.emit(event, measurements, metadata, correlation_id)

def span(operation: str, metadata: Dict = None):
    """Convenience function for spans."""
    if _telemetry:
        return _telemetry.span(operation, metadata)
    else:
        from contextlib import nullcontext
        return nullcontext()
```

### Integration in gRPC Server (grpc_server.py)

```python
async def serve():
    """Start gRPC server with telemetry."""
    server = grpc.aio.server()

    # Add bridge service
    bridge_service = BridgeServer()
    pb2_grpc.add_SnakepitBridgeServicer_to_server(bridge_service, server)

    # Start server
    port = server.add_insecure_port('[::]:0')
    await server.start()

    # Initialize telemetry (connects back to Elixir)
    telemetry_channel = grpc.aio.insecure_channel(f'localhost:{port}')
    telemetry_stub = pb2_grpc.SnakepitBridgeStub(telemetry_channel)
    telemetry.initialize_telemetry(telemetry_stub)

    logger.info(f"GRPC_READY:{port}")

    # Emit worker ready event
    telemetry.emit(
        "worker.ready",
        {"system_time": time.time_ns()},
        {"port": port, "pid": os.getpid()}
    )

    await server.wait_for_termination()
```

### Usage in Tools

```python
from snakepit_bridge import telemetry

async def execute_tool(tool_name: str, parameters: dict, correlation_id: str):
    """Execute a tool with telemetry."""

    with telemetry.span("tool.execution", {
        "tool": tool_name,
        "correlation_id": correlation_id
    }):
        result = await actual_execution(tool_name, parameters)

        # Emit custom metrics
        telemetry.emit(
            "tool.result_size",
            {"bytes": len(str(result))},
            {"tool": tool_name},
            correlation_id
        )

        return result
```

---

## Elixir Implementation

### Telemetry Stream Handler (lib/snakepit/telemetry/grpc_stream.ex)

```elixir
defmodule Snakepit.Telemetry.GrpcStream do
  @moduledoc """
  Receives telemetry from Python workers via gRPC stream and re-emits as Elixir telemetry.
  """

  use GenServer
  require Logger

  alias Snakepit.Grpc.SnakepitBridge.{TelemetryEvent, TelemetryControl}

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def handle_telemetry_stream(stream, worker_context) do
    GenServer.cast(__MODULE__, {:handle_stream, stream, worker_context})
  end

  def update_sampling(worker_id, sampling_rate) do
    GenServer.cast(__MODULE__, {:update_sampling, worker_id, sampling_rate})
  end

  # Server Implementation

  def init(_opts) do
    state = %{
      worker_streams: %{},  # worker_id => stream
      sampling_config: %{}   # worker_id => sampling_rate
    }

    {:ok, state}
  end

  def handle_cast({:handle_stream, stream, worker_context}, state) do
    # Spawn a process to consume the stream
    spawn_link(fn -> consume_stream(stream, worker_context) end)

    new_state = put_in(state, [:worker_streams, worker_context.worker_id], stream)
    {:noreply, new_state}
  end

  def handle_cast({:update_sampling, worker_id, rate}, state) do
    # Send control message to Python
    case state.worker_streams[worker_id] do
      nil ->
        {:noreply, state}

      stream ->
        control = %TelemetryControl{
          control: {:sampling, %TelemetryControl.TelemetrySamplingUpdate{
            sampling_rate: rate
          }}
        }

        GRPC.Stub.send_request(stream, control)

        new_state = put_in(state, [:sampling_config, worker_id], rate)
        {:noreply, new_state}
    end
  end

  # Private Functions

  defp consume_stream(stream, worker_context) do
    GRPC.Stub.recv(stream)
    |> Stream.each(fn
      {:ok, event} ->
        handle_telemetry_event(event, worker_context)

      {:error, reason} ->
        Logger.warning("Telemetry stream error: #{inspect(reason)}")
    end)
    |> Stream.run()
  end

  defp handle_telemetry_event(%TelemetryEvent{} = event, worker_context) do
    # Convert protobuf to Elixir telemetry
    event_name = [:snakepit, :python | Enum.map(event.event_parts, &String.to_atom/1)]

    measurements = convert_measurements(event.measurements)

    metadata =
      convert_metadata(event.metadata)
      |> Map.put(:node, node())
      |> Map.put(:worker_id, worker_context.worker_id)
      |> Map.put(:pool_name, worker_context.pool_name)
      |> Map.put(:python_pid, worker_context.python_pid)
      |> maybe_put(:correlation_id, event.correlation_id)

    # Emit as Elixir telemetry
    :telemetry.execute(event_name, measurements, metadata)
  end

  defp convert_measurements(proto_measurements) do
    Map.new(proto_measurements, fn {key, value} ->
      elixir_value = case value.value do
        {:int_value, v} -> v
        {:float_value, v} -> v
        {:string_value, v} -> v
      end

      {String.to_atom(key), elixir_value}
    end)
  end

  defp convert_metadata(proto_metadata) do
    Map.new(proto_metadata, fn {key, value} ->
      {String.to_atom(key), value}
    end)
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

### Integration with GRPCWorker

```elixir
defmodule Snakepit.GRPCWorker do
  # ... existing code ...

  def handle_info({:grpc_connected, channel}, state) do
    # ... existing connection handling ...

    # Start telemetry stream
    case start_telemetry_stream(channel, state) do
      {:ok, stream} ->
        worker_context = %{
          worker_id: state.worker_id,
          pool_name: state.pool_name,
          python_pid: state.python_pid
        }

        Snakepit.Telemetry.GrpcStream.handle_telemetry_stream(stream, worker_context)

      {:error, reason} ->
        Logger.warning("Failed to start telemetry stream: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp start_telemetry_stream(channel, _state) do
    # Open bidirectional stream
    GRPC.Stub.connect(
      channel,
      {:snakepit_bridge, :StreamTelemetry}
    )
  end
end
```

---

## Configuration

### Elixir Side

```elixir
config :snakepit, :telemetry,
  enabled: true,
  grpc_stream: true,              # Use gRPC telemetry stream
  default_sampling_rate: 1.0,     # 100% by default
  per_worker_sampling: %{
    "worker_1" => 0.1,            # 10% sampling for specific workers
    "worker_2" => 0.5
  }
```

### Python Side (Automatic)

Python reads configuration from initial handshake or control messages:

```elixir
# During worker initialization
initial_config = %{
  telemetry_enabled: true,
  sampling_rate: 1.0
}

send_to_python(initial_config)
```

---

## Event Flow

```
┌──────────────────────────────────────────┐
│ PYTHON WORKER                             │
│                                           │
│  with telemetry.span("inference"):       │
│      result = model.predict(data)        │
│                                           │
│  telemetry.emit("inference.start", ...) │
│           │                               │
│           ▼                               │
│  [Queue] → gRPC Stream →                 │
└───────────────────────────┼──────────────┘
                            │
                    gRPC bidirectional stream
                            │
┌───────────────────────────▼──────────────┐
│ ELIXIR SNAKEPIT                           │
│                                           │
│  Telemetry.GrpcStream                    │
│    |> parse_proto()                      │
│    |> enrich_context()                   │
│    |> :telemetry.execute()               │
│                                           │
│  :telemetry.execute(                     │
│    [:snakepit, :python, :inference, :start],│
│    measurements,                          │
│    metadata                               │
│  )                                        │
└───────────────────────────┬──────────────┘
                            │
                            ▼
┌────────────────────────────────────────────┐
│ CLIENT APPLICATION                          │
│                                             │
│  :telemetry.attach(                        │
│    [:snakepit, :python, :inference, :start],│
│    handler                                  │
│  )                                          │
└─────────────────────────────────────────────┘
```

---

## Performance Characteristics

### Advantages over stderr approach:

✅ **Binary protocol** - No JSON parsing overhead
✅ **Streaming** - Events flow continuously without buffering
✅ **Backpressure** - Queue full → drop events (no worker blocking)
✅ **Typed** - Protobuf schema validation
✅ **Bidirectional** - Dynamic control from Elixir
✅ **Separate channel** - Doesn't interfere with logs

### Performance considerations:

- **Queue size**: 1000 events max before dropping
- **Async**: Background asyncio task doesn't block main thread
- **Sampling**: Configurable per-worker from Elixir
- **gRPC overhead**: ~100-200 bytes per event (protobuf + gRPC headers)

---

## Testing

### Python Side

```python
# test_telemetry.py
import pytest
from snakepit_bridge import telemetry

@pytest.mark.asyncio
async def test_telemetry_emit():
    emitter = telemetry.GrpcTelemetryEmitter()
    emitter.enabled = True

    emitter.emit(
        "test.event",
        {"value": 42},
        {"key": "test"}
    )

    # Event should be in queue
    event = await asyncio.wait_for(emitter.event_queue.get(), timeout=1.0)
    assert event.event_parts == ["test", "event"]
    assert event.measurements["value"].int_value == 42
```

### Elixir Side

```elixir
defmodule Snakepit.Telemetry.GrpcStreamTest do
  use ExUnit.Case

  test "converts protobuf event to Elixir telemetry" do
    proto_event = %TelemetryEvent{
      event_parts: ["test", "start"],
      measurements: %{"duration" => %{value: {:int_value, 123}}},
      metadata: %{"key" => "value"},
      timestamp_ns: System.system_time(:nanosecond),
      correlation_id: "abc-123"
    }

    worker_context = %{
      worker_id: "test_worker",
      pool_name: :default,
      python_pid: 12345
    }

    :telemetry.attach(
      "test-handler",
      [:snakepit, :python, :test, :start],
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    GrpcStream.handle_telemetry_event(proto_event, worker_context)

    assert_receive {:telemetry,
      [:snakepit, :python, :test, :start],
      %{duration: 123},
      metadata
    }

    assert metadata.worker_id == "test_worker"
    assert metadata.correlation_id == "abc-123"
  end
end
```

---

## Migration Path

### Phase 2.1 (Initial): gRPC Stream (THIS)
- Implement gRPC telemetry service
- Python emits via gRPC
- Elixir receives and re-emits

### Phase 2.2 (Future): Pluggable Backends
- Abstract Python telemetry backend
- Support OpenTelemetry, StatsD, etc. as alternatives
- gRPC remains default

### Fallback: stderr (Simple Mode)
- For non-gRPC adapters or debugging
- Simple `TELEMETRY:{json}` on stderr
- Less efficient but works everywhere

---

**Next:** [05_WORKER_BACKENDS.md](./05_WORKER_BACKENDS.md) - Flexible backend architecture
