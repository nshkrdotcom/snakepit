# Flexible Worker-Side Telemetry Backends

**Date:** 2025-10-28
**Status:** Design Document - Future Phases

How Python workers support multiple telemetry backends.

---

## Design Philosophy

**Snakepit workers should support pluggable telemetry backends** so users can choose the best fit for their infrastructure:

- **gRPC Stream** (Phase 2.1 - Initial) - Default, integrated with Snakepit
- **OpenTelemetry** (Phase 2.2) - Industry standard, rich ecosystem
- **StatsD/DogStatsD** (Phase 2.3) - Simple UDP metrics
- **Prometheus** (Phase 2.4) - Pull-based scraping
- **stderr** (Fallback) - Zero-dependency simple mode

---

## Backend Architecture

### Abstract Base (snakepit_bridge/telemetry.py)

```python
"""
Pluggable telemetry backend system.
"""
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional
from contextlib import contextmanager
import time


class TelemetryBackend(ABC):
    """Abstract base for telemetry backends."""

    @abstractmethod
    def emit(self,
             event_name: str,
             measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """Emit a telemetry event."""
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


class TelemetryManager:
    """Manages the active telemetry backend."""

    def __init__(self):
        self.backend: Optional[TelemetryBackend] = None
        self.enabled = True

    def set_backend(self, backend: TelemetryBackend):
        """Set the active backend."""
        self.backend = backend

    def emit(self, event: str, measurements: Dict, metadata: Dict = None, correlation_id: str = None):
        """Emit via active backend."""
        if self.enabled and self.backend:
            try:
                self.backend.emit(event, measurements, metadata, correlation_id)
            except Exception:
                # Never crash due to telemetry
                pass

    def span(self, operation: str, metadata: Dict = None):
        """Create a span via active backend."""
        if self.enabled and self.backend:
            return self.backend.span(operation, metadata)
        else:
            from contextlib import nullcontext
            return nullcontext()


# Global manager
_manager = TelemetryManager()

def set_backend(backend: TelemetryBackend):
    """Set the active telemetry backend."""
    _manager.set_backend(backend)

def emit(event: str, measurements: Dict, metadata: Dict = None, correlation_id: str = None):
    """Convenience: emit via active backend."""
    _manager.emit(event, measurements, metadata, correlation_id)

def span(operation: str, metadata: Dict = None):
    """Convenience: create span via active backend."""
    return _manager.span(operation, metadata)
```

---

## Backend Implementations

### 1. gRPC Backend (Phase 2.1 - INITIAL)

**Files:** `snakepit_bridge/telemetry_stream.py`, `snakepit_bridge/telemetry/grpc_backend.py`

```python
"""
gRPC telemetry backend - sends events to Elixir via gRPC stream.
"""
from typing import Dict, Any, Optional
from ..telemetry import TelemetryBackend
from ..telemetry_stream import TelemetryStream  # wraps BridgeService.StreamTelemetry


class GrpcBackend(TelemetryBackend):
    """Sends telemetry via gRPC stream to Elixir."""

    def __init__(self, stream: TelemetryStream):
        self.stream = stream

    async def start(self):
        """No-op: server-side stream is owned by BridgeService."""
        return None

    def emit(self, event_name: str, measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """Emit event via gRPC."""

        self.stream.emit(
            event_name,
            measurements,
            metadata,
            correlation_id,
        )
```

**Usage:**
```python
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge.telemetry.grpc_backend import GrpcBackend
from snakepit_bridge import telemetry

# During worker initialization
stream = telemetry.TelemetryStream()
telemetry.install_stream(stream)

backend = GrpcBackend(stream)
set_backend(backend)
```

`TelemetryStream` centralises the gRPC plumbing (queue management, control handling)
so every backend uses the same atom-safe event conversion path before data reaches
Elixir.

---

### 2. OpenTelemetry Backend (Phase 2.2 - FUTURE)

**File:** `snakepit_bridge/telemetry/otel_backend.py`

```python
"""
OpenTelemetry backend - uses OpenTelemetry Python SDK.
"""
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

from ..telemetry import TelemetryBackend


class OpenTelemetryBackend(TelemetryBackend):
    """Uses OpenTelemetry SDK for traces and metrics."""

    def __init__(self, service_name: str = "snakepit-worker"):
        # Setup tracer
        trace.set_tracer_provider(TracerProvider())
        trace.get_tracer_provider().add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter())
        )
        self.tracer = trace.get_tracer(service_name)

        # Setup meter
        metrics.set_meter_provider(MeterProvider())
        metrics.get_meter_provider().add_metric_reader(
            PeriodicExportingMetricReader(OTLPMetricExporter())
        )
        self.meter = metrics.get_meter(service_name)

        # Create instruments
        self.counters = {}
        self.histograms = {}

    def emit(self, event_name: str, measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """Emit as OpenTelemetry span or metric."""

        # Span events (start/stop/exception)
        if event_name.endswith('.start'):
            self._start_span(event_name, metadata, correlation_id)

        elif event_name.endswith('.stop'):
            self._end_span(event_name, measurements, metadata)

        elif event_name.endswith('.exception'):
            self._record_exception(event_name, measurements, metadata)

        # Metric events
        else:
            self._record_metric(event_name, measurements, metadata)

    def _start_span(self, event_name, metadata, correlation_id):
        """Start an OpenTelemetry span."""
        operation = event_name.replace('.start', '')
        span = self.tracer.start_span(operation)

        if correlation_id:
            span.set_attribute("correlation_id", correlation_id)

        for key, value in (metadata or {}).items():
            span.set_attribute(key, value)

        # Store span in context
        # (implementation details...)

    def _record_metric(self, event_name, measurements, metadata):
        """Record a metric."""
        for key, value in measurements.items():
            metric_name = f"{event_name}.{key}"

            if isinstance(value, (int, float)):
                if metric_name not in self.histograms:
                    self.histograms[metric_name] = self.meter.create_histogram(metric_name)

                self.histograms[metric_name].record(
                    value,
                    attributes=metadata or {}
                )
```

**Usage:**
```python
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge.telemetry.otel_backend import OpenTelemetryBackend

# During worker initialization
backend = OpenTelemetryBackend(service_name="my-app-python-worker")
set_backend(backend)
```

**Benefits:**
- Industry standard
- Rich ecosystem (Jaeger, Zipkin, Prometheus, etc.)
- Distributed tracing across services
- Automatic instrumentation for popular libraries

---

### 3. StatsD Backend (Phase 2.3 - FUTURE)

**File:** `snakepit_bridge/telemetry/statsd_backend.py`

```python
"""
StatsD backend - sends metrics via UDP.
"""
import socket
from typing import Dict, Any, Optional
from ..telemetry import TelemetryBackend


class StatsDBackend(TelemetryBackend):
    """Sends telemetry to StatsD/DogStatsD via UDP."""

    def __init__(self, host: str = "localhost", port: int = 8125, prefix: str = "snakepit"):
        self.host = host
        self.port = port
        self.prefix = prefix
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def emit(self, event_name: str, measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """Send metrics to StatsD."""

        metric_name = f"{self.prefix}.{event_name}"

        # Convert measurements to StatsD format
        for key, value in measurements.items():
            if isinstance(value, (int, float)):
                # Timing for duration
                if key == "duration":
                    self._send_timing(metric_name, value, metadata)

                # Gauge for other values
                else:
                    self._send_gauge(f"{metric_name}.{key}", value, metadata)

        # Increment counter for event
        self._send_counter(metric_name, metadata)

    def _send_timing(self, metric: str, value_ns: int, tags: Dict):
        """Send timing metric (convert nanoseconds to milliseconds)."""
        value_ms = value_ns / 1_000_000
        self._send(f"{metric}:{value_ms}|ms{self._format_tags(tags)}")

    def _send_gauge(self, metric: str, value: float, tags: Dict):
        """Send gauge metric."""
        self._send(f"{metric}:{value}|g{self._format_tags(tags)}")

    def _send_counter(self, metric: str, tags: Dict):
        """Send counter increment."""
        self._send(f"{metric}:1|c{self._format_tags(tags)}")

    def _format_tags(self, tags: Optional[Dict]) -> str:
        """Format tags for DogStatsD."""
        if not tags:
            return ""

        tag_str = ",".join(f"{k}:{v}" for k, v in tags.items())
        return f"|#{tag_str}"

    def _send(self, message: str):
        """Send UDP packet."""
        try:
            self.socket.sendto(message.encode('utf-8'), (self.host, self.port))
        except Exception:
            pass  # Never crash
```

**Usage:**
```python
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge.telemetry.statsd_backend import StatsDBackend

# During worker initialization
backend = StatsDBackend(host="statsd.local", port=8125)
set_backend(backend)
```

---

### 4. stderr Backend (Fallback)

**File:** `snakepit_bridge/telemetry/stderr_backend.py`

```python
"""
stderr backend - writes JSON to stderr for Elixir to parse.

This is the simplest fallback mode, useful for:
- Non-gRPC adapters
- Debugging
- Minimal dependencies
"""
import sys
import json
import time
from typing import Dict, Any, Optional
from ..telemetry import TelemetryBackend


class StderrBackend(TelemetryBackend):
    """Writes telemetry as JSON to stderr."""

    def emit(self, event_name: str, measurements: Dict[str, Any],
             metadata: Optional[Dict[str, Any]] = None,
             correlation_id: Optional[str] = None):
        """Write event as JSON to stderr."""

        payload = {
            "event": event_name,
            "measurements": measurements or {},
            "metadata": metadata or {},
            "timestamp_ns": time.time_ns(),
            "correlation_id": correlation_id or ""
        }

        try:
            line = f"TELEMETRY:{json.dumps(payload)}\n"
            sys.stderr.write(line)
            sys.stderr.flush()
        except Exception:
            pass  # Never crash
```

**Usage:**
```python
from snakepit_bridge.telemetry import set_backend
from snakepit_bridge.telemetry.stderr_backend import StderrBackend

# Simplest mode
backend = StderrBackend()
set_backend(backend)
```

---

## Backend Selection

### Automatic (via Environment Variable)

```python
# snakepit_bridge/__init__.py

import os
from .telemetry import set_backend
from . import telemetry

def initialize_telemetry():
    """Initialize telemetry with configured backend."""
    backend_type = os.getenv("SNAKEPIT_TELEMETRY_BACKEND", "grpc")

    if backend_type == "grpc":
        from .telemetry.grpc_backend import GrpcBackend
        stream = telemetry.TelemetryStream()
        telemetry.install_stream(stream)
        backend = GrpcBackend(stream)

    elif backend_type == "otel":
        from .telemetry.otel_backend import OpenTelemetryBackend
        service_name = os.getenv("SNAKEPIT_SERVICE_NAME", "snakepit-worker")
        backend = OpenTelemetryBackend(service_name)

    elif backend_type == "statsd":
        from .telemetry.statsd_backend import StatsDBackend
        host = os.getenv("STATSD_HOST", "localhost")
        port = int(os.getenv("STATSD_PORT", "8125"))
        backend = StatsDBackend(host, port)

    elif backend_type == "stderr":
        from .telemetry.stderr_backend import StderrBackend
        backend = StderrBackend()

    else:
        # No telemetry
        return

    set_backend(backend)
```

### Elixir Configuration

```elixir
# config/config.exs
config :snakepit, :telemetry,
  # Backend selection
  python_backend: :grpc,  # :grpc | :otel | :statsd | :stderr

  # gRPC backend config
  grpc_stream: true,

  # OpenTelemetry config (if using otel backend)
  otel_endpoint: "http://localhost:4317",
  otel_service_name: "my-app-python",

  # StatsD config (if using statsd backend)
  statsd_host: "localhost",
  statsd_port: 8125
```

```elixir
# Pass to Python via environment
defp python_env(config) do
  backend = Keyword.get(config, :python_backend, :grpc)

  base_env = [
    {"SNAKEPIT_TELEMETRY_BACKEND", to_string(backend)}
  ]

  case backend do
    :otel ->
      base_env ++
      [
        {"OTEL_EXPORTER_OTLP_ENDPOINT", config[:otel_endpoint]},
        {"SNAKEPIT_SERVICE_NAME", config[:otel_service_name]}
      ]

    :statsd ->
      base_env ++
      [
        {"STATSD_HOST", config[:statsd_host]},
        {"STATSD_PORT", to_string(config[:statsd_port])}
      ]

    _ ->
      base_env
  end
end
```

---

## Use Cases

### Use gRPC Backend When:
✅ Using Snakepit with default gRPC adapter
✅ Want telemetry in Elixir `:telemetry` format
✅ Need dynamic control (sampling, filtering) from Elixir
✅ Single monitoring system (Elixir-centric)

### Use OpenTelemetry Backend When:
✅ Multi-language microservices (need standard)
✅ Want distributed tracing across services
✅ Using Jaeger, Zipkin, or other OTel-compatible systems
✅ Need rich instrumentation ecosystem

### Use StatsD Backend When:
✅ Already have StatsD/DogStatsD infrastructure
✅ Simple metrics, don't need full tracing
✅ Want fire-and-forget UDP (no backpressure)
✅ Using Datadog or similar StatsD-based systems

### Use stderr Backend When:
✅ Debugging or development
✅ Non-gRPC adapter (simple Port mode)
✅ Minimal dependencies required
✅ Quick prototyping

---

## Multi-Backend Support (Future)

Could support **multiple backends simultaneously**:

```python
from snakepit_bridge.telemetry import TelemetryManager

manager = TelemetryManager()

# Send to both gRPC (for Elixir) AND OpenTelemetry (for tracing)
manager.add_backend(GrpcBackend(stub))
manager.add_backend(OpenTelemetryBackend())

# Events emitted to both backends
telemetry.emit("inference.start", {...})
```

---

## Implementation Phases

### ✅ Phase 2.1 (THIS RELEASE)
- gRPC backend (initial implementation)
- Python emits via gRPC stream
- Elixir receives and re-emits as `:telemetry`

### Phase 2.2
- Pluggable backend architecture
- OpenTelemetry backend
- Backend selection via config

### Phase 2.3
- StatsD backend
- Prometheus scraping support
- Multi-backend support

### Phase 2.4
- Performance optimizations
- Custom backends via user plugins
- Advanced filtering/sampling

---

## Summary

**Architecture:**
```
┌──────────────────────────────────────────┐
│ Python Worker Code                        │
│  from snakepit_bridge.telemetry import * │
│  telemetry.emit(...)                     │
└──────────────┬───────────────────────────┘
               │
        Abstract Interface
               │
    ┌──────────┴──────────┐
    │                     │
┌───▼────┐        ┌───────▼─────────┐
│ gRPC   │        │ OpenTelemetry   │  ... etc
│ Backend│        │ Backend         │
└───┬────┘        └───────┬─────────┘
    │                     │
    ▼                     ▼
  Elixir            OTel Collector
```

**Key Principles:**
1. **gRPC is default** - Tight integration with Snakepit
2. **Pluggable** - Easy to add new backends
3. **No lock-in** - Users choose what fits their stack
4. **Backward compatible** - stderr fallback always available

---

**Related:**
- [04_GRPC_STREAM.md](./04_GRPC_STREAM.md) - Initial gRPC implementation
- [00_ARCHITECTURE.md](./00_ARCHITECTURE.md) - Overall telemetry architecture
