# Python Telemetry Integration

**Date:** 2025-10-28  
**Status:** Implementation Ready

This document explains how Python workers publish telemetry that is folded back
into Elixir `:telemetry` events. It reflects the revised gRPC-first design and
shows where the stderr fallback fits for adapters that cannot use gRPC.

---

## 1. API Surface (`snakepit_bridge.telemetry`)

Workers interact with telemetry through the high-level helpers defined in
`snakepit_bridge/telemetry/__init__.py`. These helpers delegate to a pluggable
backend (see [05_WORKER_BACKENDS.md](./05_WORKER_BACKENDS.md)).

```python
# snakepit_bridge/telemetry/__init__.py (conceptual API)
from contextlib import contextmanager
from typing import Any, Dict, Optional

from .manager import set_backend as set_backend  # exported for bootstrap
from .manager import get_backend as get_backend   # for diagnostics

def emit(
    event: str,
    measurements: Dict[str, Any],
    metadata: Optional[Dict[str, Any]] = None,
    correlation_id: Optional[str] = None,
) -> None:
    """Emit a telemetry event via the active backend."""

def span(
    operation: str,
    metadata: Optional[Dict[str, Any]] = None,
    correlation_id: Optional[str] = None,
) -> contextmanager:
    """Context manager that emits start/stop/exception events."""
```

- `event` names use dotted notation (`tool.execution.start`).
- Measurements are numeric when possible; strings are coerced.
- Metadata values are coerced to strings before crossing the boundary.
- `correlation_id` propagates tracing information from Elixir (if provided).

All user code and bridge utilities call these helpers so backend changes do not
affect instrumentation sites.

---

## 2. Default Backend (gRPC Stream)

### 2.1 Bootstrap

During worker startup, the gRPC backend is installed after the worker knows its
BridgeService implementation. The backend owns the `TelemetryStream` described
in [04_GRPC_STREAM.md](./04_GRPC_STREAM.md).

```python
# priv/python/grpc_server.py (excerpt)
import grpc

from snakepit_bridge.telemetry.stream import TelemetryStream
from snakepit_bridge.telemetry.backends.grpc import GrpcBackend
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge import snakepit_bridge_pb2_grpc as pb2_grpc


class BridgeService(pb2_grpc.BridgeServiceServicer):
    def __init__(self) -> None:
        self.telemetry_stream = TelemetryStream()
        set_backend(GrpcBackend(self.telemetry_stream))

    async def StreamTelemetry(self, request_iterator, context):
        return self.telemetry_stream.stream(request_iterator, context)

    # ...existing RPCs...


async def serve():
    server = grpc.aio.server()
    service = BridgeService()
    pb2_grpc.add_BridgeServiceServicer_to_server(service, server)
    # ...existing bootstrap...
```

- A single `TelemetryStream` instance is shared across all instrumentation.
- `GrpcBackend` converts `emit` calls into protobuf events and pushes them onto
  the gRPC response stream.
- Control messages from Elixir (`TelemetryControl`) update `TelemetryStream`
  state (sampling, enable/disable) without restarting the worker.

### 2.2 Instrumentation Helpers

Workers continue to call `telemetry.emit` / `telemetry.span` exactly as before.
The backend handles serialization and queueing.

```python
from snakepit_bridge.telemetry import emit, span


async def execute_tool(tool_name: str, parameters: dict, correlation_id: str):
    """Execute a tool with structured telemetry."""

    with span("tool.execution", {"tool": tool_name}, correlation_id):
        result = await do_execute(tool_name, parameters)

        emit(
            "tool.result_size",
            {"bytes": len(str(result))},
            {"tool": tool_name},
            correlation_id,
        )

        return result
```

The helper ensures the same event catalog whether telemetry flows over gRPC or
stderr.

---

## 3. Telemetry Event Guidelines

| Aspect          | Guidance                                                                 |
|-----------------|--------------------------------------------------------------------------|
| Event names     | Dotted strings (`component.resource.action`) that map onto the catalog.  |
| Measurements    | Numeric or short string values. Prefer integers for counters/duration.   |
| Metadata keys   | Lowercase strings; values stringified to avoid Python object pickling.   |
| Node awareness  | Elixir enriches metadata with `node`, `worker_id`, `pool_name`, etc.     |
| Correlation IDs | Pass through from Elixir request metadata when available.                |

The canonical mapping from strings to atoms lives in
`Snakepit.Telemetry.Naming`. If a new event is required, update the catalog and
module before emitting it from Python.

---

## 4. stderr Fallback (Compatibility Path)

Some adapters (e.g., process-mode without gRPC) cannot rely on the telemetry
stream. For those environments use the stderr backend, which reuses the same
high-level API:

```python
# snakepit_bridge/telemetry/backends/stderr.py
import sys
import json
import time
from typing import Any, Dict, Optional

from .base import TelemetryBackend


class StderrBackend(TelemetryBackend):
    def emit(
        self,
        event_name: str,
        measurements: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None,
        correlation_id: Optional[str] = None,
    ) -> None:
        payload = {
            "event": event_name,
            "measurements": measurements,
            "metadata": metadata or {},
            "timestamp_ns": time.time_ns(),
            "correlation_id": correlation_id,
        }
        sys.stderr.write(f"TELEMETRY:{json.dumps(payload)}\n")
        sys.stderr.flush()
```

Switching backends only changes the bootstrap code:

```python
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge.telemetry.backends.stderr import StderrBackend

set_backend(StderrBackend())
```

The Elixir side already supports parsing stderr telemetry via
`Snakepit.Telemetry.PythonCapture`, so both transports converge on the same
runtime behaviour.

---

## 5. Testing Guidance

### 5.1 Unit Tests (Python)

- `priv/python/tests/test_telemetry_stream.py` – validates gRPC stream queueing.
- `priv/python/tests/test_telemetry_helpers.py` – covers `emit`, `span`, and
  backend switching.
- `priv/python/tests/test_stderr_backend.py` – ensures stderr payload matches
  expectations.

### 5.2 Integration Tests

- `priv/python/tests/test_telemetry_end_to_end.py` bootstraps a worker, emits an
  event, and asserts Elixir receives it (executed via `make test`).
- Fixtures record queue drop counts by reading `TelemetryStream` metrics.

### 5.3 Developer Tooling

- `PYTHON_SNAKEPIT_TELEMETRY=stderr` switches the backend for local debugging.
- `MIX_ENV=dev mix run examples/telemetry_demo.exs` exercises the stream end-to-end.

---

## 6. Operational Checklist

1. Ensure the worker installs the gRPC backend before processing user requests.
2. Forward Elixir-provided correlation IDs through worker RPC metadata to keep
   traces connected.
3. Monitor `TelemetryStream` queue saturation metrics (exposed via
   `Snakepit.Telemetry.GrpcStream`) to adjust sampling in production.
4. Update the event catalog and helper enums when introducing new events.
5. Document any environment-specific telemetry configuration in
   `docs/operations/telemetry.md`.
