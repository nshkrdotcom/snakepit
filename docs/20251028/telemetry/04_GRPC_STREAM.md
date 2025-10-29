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

// Telemetry RPC lives on the existing BridgeService so current
// clients continue to generate Snakepit.Bridge modules.
service BridgeService {
  // Existing RPCs...
  rpc ExecuteTool(...) returns (...);
  rpc ExecuteStreamingTool(...) returns (...);

  // NEW: Telemetry stream (bidirectional)
  rpc StreamTelemetry(stream TelemetryControl) returns (stream TelemetryEvent);
}

// Telemetry event from Python → Elixir
message TelemetryEvent {
  // Event name parts – validated against the catalog on the Elixir side.
  repeated string event_parts = 1;

  // Measurements (numeric data)
  map<string, TelemetryValue> measurements = 2;

  // Metadata (contextual information). Keys stay as strings so Elixir
  // never creates new atoms.
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

Elixir (client) writes `TelemetryControl` messages on the request stream; the Python
worker (server) yields `TelemetryEvent` responses as telemetry is produced. This keeps
transport responsibilities aligned with the existing BridgeService ownership.

---

## Python Implementation

### Telemetry Stream (snakepit_bridge/telemetry.py)

```python
"""
Telemetry stream support for Snakepit workers.

The worker exposes BridgeService.StreamTelemetry. Elixir opens a
bidi stream: Python pushes telemetry events, Elixir sends control.
"""
import asyncio
import random
import time
from contextlib import contextmanager
from typing import Any, AsyncIterable, Dict, Optional

from . import snakepit_bridge_pb2 as pb2


class TelemetryStream:
    """Provides emit/span helpers backed by the gRPC telemetry stream."""

    def __init__(self) -> None:
        self.enabled = True
        self.sampling_rate = 1.0
        self._event_queue: asyncio.Queue[pb2.TelemetryEvent] = asyncio.Queue(maxsize=1000)

    async def stream_telemetry(
        self,
        control_iter: AsyncIterable[pb2.TelemetryControl],
        _context: Any,
    ):
        """
        gRPC handler invoked for BridgeService.StreamTelemetry.
        """

        async def consume_control():
            async for control in control_iter:
                self._handle_control(control)

        control_task = asyncio.create_task(consume_control())

        try:
            while True:
                event = await self._event_queue.get()
                if event is None:
                    break
                yield event
        finally:
            control_task.cancel()

    def _handle_control(self, control: pb2.TelemetryControl) -> None:
        if control.HasField("sampling"):
            self.sampling_rate = min(max(control.sampling.sampling_rate, 0.0), 1.0)
        elif control.HasField("toggle"):
            self.enabled = control.toggle.enabled

    def emit(
        self,
        event_name: str,
        measurements: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        if not self.enabled:
            return

        if self.sampling_rate < 1.0 and random.random() > self.sampling_rate:
            return

        event = pb2.TelemetryEvent(
            event_parts=event_name.split("."),
            timestamp_ns=time.time_ns(),
            correlation_id=correlation_id or "",
        )

        for key, value in (measurements or {}).items():
            target = event.measurements[key]
            if isinstance(value, int):
                target.int_value = value
            elif isinstance(value, float):
                target.float_value = value
            else:
                target.string_value = str(value)

        for key, value in (metadata or {}).items():
            event.metadata[key] = str(value)

        try:
            self._event_queue.put_nowait(event)
        except asyncio.QueueFull:
            pass  # Drop instead of blocking the worker

    @contextmanager
    def span(self, operation: str, metadata: Optional[Dict[str, Any]] = None):
        meta = metadata or {}
        start_time = time.perf_counter_ns()

        self.emit(
            f"{operation}.start",
            {"system_time": time.time_ns()},
            meta,
        )

        try:
            yield
        except Exception as exc:
            duration = time.perf_counter_ns() - start_time
            self.emit(
                f"{operation}.exception",
                {"duration": duration, "system_time": time.time_ns()},
                {
                    **meta,
                    "result": "error",
                    "error_type": type(exc).__name__,
                    "error_message": str(exc),
                },
            )
            raise
        else:
            duration = time.perf_counter_ns() - start_time
            self.emit(
                f"{operation}.stop",
                {"duration": duration, "system_time": time.time_ns()},
                {**meta, "result": "success"},
            )


telemetry_stream: Optional[TelemetryStream] = None


def install_stream(stream: TelemetryStream) -> None:
    global telemetry_stream
    telemetry_stream = stream


def emit(event: str, measurements: Dict, metadata: Dict = None, correlation_id: str = None):
    if telemetry_stream:
        telemetry_stream.emit(event, measurements, metadata, correlation_id)


def span(operation: str, metadata: Dict = None):
    if telemetry_stream:
        return telemetry_stream.span(operation, metadata)
    from contextlib import nullcontext

    return nullcontext()
```

### Integration in gRPC Server (grpc_server.py)

```python
async def serve():
    """Start gRPC server with telemetry."""
    server = grpc.aio.server()

    telemetry.install_stream(telemetry.TelemetryStream())

    bridge_service = BridgeServer()
    pb2_grpc.add_BridgeServiceServicer_to_server(bridge_service, server)

    port = server.add_insecure_port("[::]:0")
    await server.start()

    logger.info(f"GRPC_READY:{port}")

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

  alias Snakepit.Bridge.{TelemetryControl, TelemetryEvent}
  alias Snakepit.Telemetry.{Naming, SafeMetadata}

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
    {:ok, %{worker_streams: %{}, sampling_config: %{}}}
  end

  def handle_cast({:handle_stream, stream, worker_context}, state) do
    listener =
      Task.Supervisor.async_nolink(Snakepit.Telemetry.TaskSupervisor, fn ->
        consume_stream(stream, worker_context)
      end)

    new_state =
      state
      |> put_in([:worker_streams, worker_context.worker_id], %{stream: stream, task: listener})

    {:noreply, new_state}
  end

  def handle_cast({:update_sampling, worker_id, rate}, state) do
    case state.worker_streams[worker_id] do
      nil ->
        {:noreply, state}

      %{stream: stream} ->
        control = TelemetryControl.new_sampling(rate)
        :ok = GRPC.Stub.stream_send(stream, control)

        {:noreply, put_in(state, [:sampling_config, worker_id], rate)}
    end
  end

  # Private Functions

  defp consume_stream(stream, worker_context) do
    stream
    |> GRPC.Stub.recv()
    |> Enum.each(fn
      {:ok, %TelemetryEvent{} = event} ->
        handle_telemetry_event(event, worker_context)

      {:error, reason} ->
        Logger.warning("Telemetry stream error: #{inspect(reason)}")
    end)
  end

  defp handle_telemetry_event(%TelemetryEvent{} = event, worker_context) do
    with {:ok, event_name} <- Naming.from_parts(event.event_parts),
         {:ok, measurements} <- cast_measurements(event.measurements),
         {:ok, metadata} <-
           SafeMetadata.enrich(event.metadata,
             node: node(),
             worker_id: worker_context.worker_id,
             pool_name: worker_context.pool_name,
             python_pid: worker_context.python_pid,
             correlation_id: blank_to_nil(event.correlation_id)
           ) do
      :telemetry.execute(event_name, measurements, metadata)
    else
      {:error, reason} ->
        Logger.debug("Skipping telemetry event #{inspect(event.event_parts)}: #{inspect(reason)}")
    end
  end

  defp cast_measurements(proto_measurements) do
    Enum.reduce_while(proto_measurements, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Naming.measurement_key(key) do
        {:ok, atom_key} ->
          val =
            case value.value do
              {:int_value, v} -> v
              {:float_value, v} -> v
              {:string_value, v} -> v
            end

          {:cont, {:ok, Map.put(acc, atom_key, val)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_measurement_key, key, reason}}}
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
```

Key guardrails:

- `Snakepit.Telemetry.Naming` keeps the canonical list of event parts and
  measurement keys; it only allows values that were pre-registered from the
  design catalog, avoiding `String.to_atom/1`.
- `Snakepit.Telemetry.SafeMetadata` enriches metadata with known atom keys (`:node`,
  `:worker_id`, etc.) but stores arbitrary Python-provided keys as strings so the BEAM
  atom table is never polluted.
- `Snakepit.Telemetry.Control.new_sampling/1` (and similar helpers) wrap the
  verbose protobuf structs so the call-sites stay small while still producing the
  generated `%Snakepit.Bridge.TelemetryControl{}` shape.

```elixir
defmodule Snakepit.Telemetry.Control do
  alias Snakepit.Bridge.TelemetryControl

  def toggle(enabled) do
    %TelemetryControl{control: {:toggle, %TelemetryControl.TelemetryToggle{enabled: enabled}}}
  end

  def new_sampling(rate) do
    %TelemetryControl{control: {:sampling, %TelemetryControl.TelemetrySamplingUpdate{sampling_rate: rate}}}
  end
end
```

### Integration with GRPCWorker

```elixir
defmodule Snakepit.GRPCWorker do
  # ... existing code ...

  alias Snakepit.Bridge.TelemetryControl
  alias Snakepit.Telemetry.Control

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
    # Open bidirectional stream with an initial control frame
    initial = [Control.toggle(true)]

    Snakepit.Bridge.BridgeService.Stub.stream_telemetry(channel, initial)
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
- **Async**: `emit/4` enqueues instantly; the gRPC response stream drains the queue
- **Sampling**: Configurable per-worker from Elixir
- **gRPC overhead**: ~100-200 bytes per event (protobuf + gRPC headers)

---

## Testing

### Python Side

```python
# test_telemetry.py
import asyncio
import pytest
from snakepit_bridge import telemetry


@pytest.mark.asyncio
async def test_telemetry_emit():
    stream = telemetry.TelemetryStream()
    telemetry.install_stream(stream)

    stream.emit(
        "test.event",
        {"value": 42},
        {"key": "test"}
    )

    event = await asyncio.wait_for(stream._event_queue.get(), timeout=1.0)
    assert event.event_parts == ["test", "event"]
    assert event.measurements["value"].int_value == 42
```

In production the queue stays private; tests can poke `_event_queue` to assert that
emissions enqueue protobuf payloads correctly.

### Elixir Side

```elixir
defmodule Snakepit.Telemetry.GrpcStreamTest do
  use ExUnit.Case

  alias Snakepit.Bridge.TelemetryEvent
  alias Snakepit.Telemetry.GrpcStream

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
