# gRPC Telemetry Stream Blueprint

**Date:** 2025-10-28  
**Status:** Implementation Ready (Phase 2.1)

The gRPC telemetry stream is the canonical transport for folding Python worker
telemetry into Elixir `:telemetry` events. This document replaces the earlier
exploratory draft and describes an implementation that can be applied to the
current Snakepit stack without additional libraries.

---

## 1. Goals & Scope

- Deliver a back-pressure-aware, bidirectional telemetry channel between
  Python workers (gRPC server) and Elixir (gRPC client).
- Preserve Elixir as the single integration point for downstream observers.
- Allow Elixir to adjust sampling, enable/disable, or filter events without
  restarting workers.
- Remain compatible with the existing `BridgeService` proto and tooling.

Out of scope for Phase 2.1: pluggable Python backends beyond gRPC, external
exports (Prometheus/OTLP), or protobuf oneofs for arbitrary payloads.

---

## 2. RPC Contract

### Proto Changes

```protobuf
// snakepit_bridge.proto

service BridgeService {
  // ...existing RPCs...

  // NEW: Bidirectional telemetry stream initiated by Elixir.
  rpc StreamTelemetry(stream TelemetryControl) returns (stream TelemetryEvent);
}

message TelemetryEvent {
  repeated string event_parts = 1;               // validated by Elixir catalog
  map<string, TelemetryValue> measurements = 2;  // numeric/categorical values
  map<string, string> metadata = 3;              // contextual data (string keys)
  int64 timestamp_ns = 4;                        // unix epoch, nanoseconds
  string correlation_id = 5;                     // optional tracing correlation
}

message TelemetryValue {
  oneof value {
    int64 int_value = 1;
    double float_value = 2;
    string string_value = 3;
  }
}

message TelemetryControl {
  oneof control {
    TelemetryToggle toggle = 1;
    TelemetrySamplingUpdate sampling = 2;
    TelemetryEventFilter filter = 3;
  }
}

message TelemetryToggle {
  bool enabled = 1;
}

message TelemetrySamplingUpdate {
  double sampling_rate = 1;               // 0.0 ≤ rate ≤ 1.0
  repeated string event_patterns = 2;     // glob-style patterns (e.g. "python.*")
}

message TelemetryEventFilter {
  repeated string allow = 1;              // explicit whitelist
  repeated string deny = 2;               // explicit blacklist
}
```

Implementation checklist:

1. Update `priv/proto/snakepit_bridge.proto`.
2. Regenerate code with `mix grpc.gen` (Elixir) and `make proto-python` (Python).
3. Commit regenerated files alongside the proto update.

### Stream Semantics

- **Initiator:** Elixir opens the stream after a worker is connected.
- **Request stream:** Elixir sends `TelemetryControl` frames to adjust worker
  behaviour. It keeps the stream half-open for future updates.
- **Response stream:** Python yields `TelemetryEvent` frames as telemetry is
  produced.
- **Lifecycle:** When either side terminates the stream (disconnect, worker
  shutdown, or explicit toggle), both request and response streams close.

---

## 3. Python Worker Implementation

The Python side owns the gRPC service and therefore implements the stream
handler. The recommended implementation uses an internal `TelemetryStream`
object that decouples event production from the gRPC transport.

### 3.1 Telemetry Stream

```python
# priv/python/snakepit_bridge/telemetry/stream.py
import asyncio
import random
import time
from typing import Any, AsyncIterable, Dict, Optional

from . import snakepit_bridge_pb2 as pb


class TelemetryStream:
    """Collects events and flushes them onto the gRPC response stream."""

    def __init__(self, max_buffer: int = 1024) -> None:
        self.enabled = True
        self.sampling_rate = 1.0
        self._queue: asyncio.Queue[pb.TelemetryEvent] = asyncio.Queue(maxsize=max_buffer)

    async def stream(
        self,
        control_iter: AsyncIterable[pb.TelemetryControl],
        _context: Any,
    ):
        """BridgeService.StreamTelemetry implementation."""

        async def consume_control() -> None:
            async for control in control_iter:
                self._handle_control(control)

        control_task = asyncio.create_task(consume_control())

        try:
            while True:
                event = await self._queue.get()
                if event is None:
                    break
                yield event
        finally:
            control_task.cancel()

    def emit(
        self,
        event_name: str,
        measurements: Dict[str, float | int | str],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        if not self.enabled:
            return
        if self.sampling_rate < 1.0 and random.random() > self.sampling_rate:
            return

        event = pb.TelemetryEvent(
            event_parts=event_name.split("."),
            timestamp_ns=time.time_ns(),
            correlation_id=correlation_id or "",
        )

        for key, value in measurements.items():
            if isinstance(value, bool):
                value = int(value)
            field = event.measurements[key]
            if isinstance(value, int):
                field.int_value = value
            elif isinstance(value, float):
                field.float_value = value
            else:
                field.string_value = str(value)

        for key, value in (metadata or {}).items():
            event.metadata[key] = str(value)

        try:
            self._queue.put_nowait(event)
        except asyncio.QueueFull:
            # Drop instead of blocking critical worker code.
            pass

    def _handle_control(self, control: pb.TelemetryControl) -> None:
        which = control.WhichOneof("control")
        if which == "toggle":
            self.enabled = control.toggle.enabled
        elif which == "sampling":
            self.sampling_rate = max(0.0, min(control.sampling.sampling_rate, 1.0))
        elif which == "filter":
            # Filters will be handled in Phase 2.2. For now they are acknowledged.
            pass

    def close(self) -> None:
        # Push sentinel to terminate the stream gracefully.
        try:
            self._queue.put_nowait(None)  # type: ignore[arg-type]
        except asyncio.QueueFull:
            pass
```

### 3.2 Service Integration

```python
# priv/python/grpc_server.py (excerpt)
from snakepit_bridge.telemetry.stream import TelemetryStream
from snakepit_bridge import telemetry  # high-level API (manager)
from snakepit_bridge.telemetry.backends.grpc import GrpcBackend
from snakepit_bridge import snakepit_bridge_pb2_grpc as pb2_grpc


class BridgeService(pb2_grpc.BridgeServiceServicer):
    def __init__(self) -> None:
        self.telemetry = TelemetryStream()
        telemetry.set_backend(GrpcBackend(self.telemetry))

    async def StreamTelemetry(self, request_iterator, context):
        return self.telemetry.stream(request_iterator, context)


async def serve():
    server = grpc.aio.server()
    service = BridgeService()
    pb2_grpc.add_BridgeServiceServicer_to_server(service, server)
    # ... existing setup ...
```

- `TelemetryStream` is installed once per worker.
- Worker modules call `service.telemetry.emit(...)` or wrap spans directly.
- Stderr fallback remains available and uses the same high-level API by
  swapping in `snakepit_bridge.telemetry.stream.TelemetryStream` or the stderr backend.

---

## 4. Elixir Implementation

Elixir runs the client side of the stream and re-emits events via `:telemetry`.
The design keeps all gRPC stream management inside a GenServer so worker
processes retain a narrow API.

### 4.1 Control Helpers

```elixir
# lib/snakepit/telemetry/control.ex
defmodule Snakepit.Telemetry.Control do
  alias Snakepit.Bridge.{
    TelemetryControl,
    TelemetryEventFilter,
    TelemetrySamplingUpdate,
    TelemetryToggle
  }

  def toggle(enabled) do
    %TelemetryControl{
      control: {:toggle, %TelemetryToggle{enabled: enabled}}
    }
  end

  def sampling(rate, patterns \\ []) do
    %TelemetryControl{
      control:
        {:sampling,
         %TelemetrySamplingUpdate{
           sampling_rate: rate,
           event_patterns: Enum.map(patterns, &to_string/1)
         }}
    }
  end

  def filter(allow \\ [], deny \\ []) do
    %TelemetryControl{
      control:
        {:filter,
         %TelemetryEventFilter{
           allow: Enum.map(allow, &to_string/1),
           deny: Enum.map(deny, &to_string/1)
         }}
    }
  end
end
```

### 4.2 Stream Process

```elixir
# lib/snakepit/telemetry/grpc_stream.ex
defmodule Snakepit.Telemetry.GrpcStream do
  use GenServer
  require Logger

  alias Snakepit.Bridge.BridgeService.Stub
  alias Snakepit.Bridge.{TelemetryControl, TelemetryEvent}
  alias Snakepit.Telemetry.{Control, Naming, SafeMetadata}

  @type worker_ctx :: %{
          worker_id: String.t(),
          pool_name: atom(),
          python_pid: integer()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_worker(channel, worker_ctx) do
    GenServer.cast(__MODULE__, {:register_worker, channel, worker_ctx})
  end

  def update_sampling(worker_id, rate, patterns \\ []) do
    GenServer.cast(__MODULE__, {:update_sampling, worker_id, rate, patterns})
  end

  @impl true
  def init(_opts) do
    {:ok, %{streams: %{}}}
  end

  @impl true
  def handle_cast({:register_worker, channel, worker_ctx}, state) do
    case Stub.stream_telemetry(channel, timeout: :infinity) do
      %GRPC.Client.Stream{} = stream ->
        stream = GRPC.Stub.send_request(stream, Control.toggle(true))
        listener = Task.Supervisor.async_nolink(
          Snakepit.Telemetry.TaskSupervisor,
          fn -> consume(stream, worker_ctx) end
        )

        {:noreply,
         put_in(state, [:streams, worker_ctx.worker_id], %{stream: stream, task: listener})}

      {:error, reason} ->
        Logger.warning("Unable to start telemetry stream: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:update_sampling, worker_id, rate, patterns}, state) do
    with %{stream: stream} <- Map.get(state.streams, worker_id) do
      updated_stream = GRPC.Stub.send_request(stream, Control.sampling(rate, patterns))

      {:noreply,
       put_in(state, [:streams, worker_id, :stream], updated_stream)}
    else
      _ ->
        {:noreply, state}
    end
  end

  defp consume(stream, worker_ctx) do
    with {:ok, enum} <- GRPC.Stub.recv(stream, timeout: :infinity) do
      Enum.each(enum, fn
        {:ok, %TelemetryEvent{} = event} -> translate(event, worker_ctx)
        {:error, reason} -> Logger.warning("Telemetry stream error: #{inspect(reason)}")
        {:trailers, trailers} -> Logger.debug("Telemetry stream trailers: #{inspect(trailers)}")
      end)
    else
      {:error, reason} ->
        Logger.warning("Telemetry stream closed: #{inspect(reason)}")
    end
  end

  defp translate(event, worker_ctx) do
    with {:ok, name} <- Naming.from_parts(event.event_parts),
         {:ok, measurements} <- cast_measurements(event.measurements),
         {:ok, metadata} <-
           SafeMetadata.enrich(event.metadata,
             node: node(),
             worker_id: worker_ctx.worker_id,
             pool_name: worker_ctx.pool_name,
             python_pid: worker_ctx.python_pid,
             correlation_id: blank_to_nil(event.correlation_id),
             timestamp_ns: event.timestamp_ns
           ) do
      :telemetry.execute(name, measurements, metadata)
    else
      {:error, reason} ->
        Logger.debug("Skipping telemetry event #{inspect(event.event_parts)}: #{inspect(reason)}")
    end
  end

  defp cast_measurements(measurements) do
    Enum.reduce_while(measurements, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
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

Key points:

- Streams are registered once per worker. The GenServer stores the
  `GRPC.Client.Stream` handle so subsequent control messages can reuse it.
- The stream is started with an initial `toggle(true)` control message (optional
  but keeps semantics explicit).
- `GRPC.Stub.recv/2` returns an enumerable of `{:ok, TelemetryEvent}` tuples; the
  consumer task drains it and converts each event into an Elixir telemetry event.

### 4.3 Worker Hook

```elixir
# lib/snakepit/grpc_worker.ex (excerpt)
def handle_info({:grpc_connected, channel}, state) do
  # ... existing connection code ...

  Snakepit.Telemetry.GrpcStream.register_worker(channel, %{
    worker_id: state.worker_id,
    pool_name: state.pool_name,
    python_pid: state.python_pid
  })

  {:noreply, state}
end
```

The worker process no longer needs to manage the stream directly. Control
updates (sampling, toggles) can be triggered via public APIs on the telemetry
module.

---

## 5. Operational Considerations

- **Backpressure:** The Python queue drops events when saturated instead of
  blocking core work. Elixir consumers are single-stream per worker; if a worker
  produces more events than Elixir can consume, the queue size should be
  increased or sampling reduced.
- **Supervision:** `Snakepit.Telemetry.GrpcStream` should run under its own
  supervisor with a `Task.Supervisor` (`Snakepit.Telemetry.TaskSupervisor`). If
  the stream task crashes, the GenServer restarts and reattaches once the worker
  reconnects.
- **Shutdown:** When a worker terminates, Elixir should remove its stream entry.
  Python pushes a sentinel (`None`) to flush pending events; Elixir handles
  `{:error, :cancelled}` gracefully.
- **Security:** Telemetry metadata is stringly typed. `Snakepit.Telemetry.Naming`
  and `SafeMetadata` enforce atom safety and validate known keys. New catalog
  entries must be added before Python can emit them.

---

## 6. Testing Strategy

1. **Unit tests (Elixir):**
   - Verify `Snakepit.Telemetry.Control` constructors emit the expected structs.
   - Test `cast_measurements/1` and metadata enrichment paths using generated
     protobuf structs.
   - Ensure stream registry handles reconnect and sampling updates.
2. **Unit tests (Python):**
   - Validate `TelemetryStream.emit/4` enqueues correctly typed protobuf values.
   - Cover control message handling (toggle, sampling).
3. **Integration test (Elixir ↔ Python):**
   - Use the Python fixture to start a worker.
   - Connect through `Snakepit.GRPCWorker`, emit a telemetry event from Python,
     and assert an Elixir `:telemetry` handler receives it.
4. **Load test hook:**
   - Extend `bench/` scenarios to measure throughput and queue drop counts.
5. **Regression enforcement:**
   - Add `mix test test/snakepit/telemetry/grpc_stream_test.exs`.
   - Add `pytest priv/python/tests/test_telemetry_stream.py`.

---

## 7. Migration Notes

1. Roll out proto change and regenerate stubs.
2. Introduce `Snakepit.Telemetry.GrpcStream` and supervisor wiring behind a
   feature flag (`config :snakepit, telemetry: [grpc_stream: true]`).
3. Gradually enable per-environment, monitoring queue drop counts and worker CPU.
4. Once the gRPC stream is stable, deprecate the stderr fallback for gRPC
   workers (retained only for process-mode adapters).

---

**Next:** [05_WORKER_BACKENDS.md](./05_WORKER_BACKENDS.md) describes extending the
Python telemetry API with additional backends after Phase 2.1 ships.
