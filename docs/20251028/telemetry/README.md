# Snakepit Distributed Telemetry System

**Date:** 2025-10-28
**Status:** Design Phase - Ready for Implementation

This directory contains the complete design for Snakepit's distributed telemetry system.

---

## 📚 Documentation Index

### Core Design

1. **[00_ARCHITECTURE.md](./00_ARCHITECTURE.md)** - System architecture and design principles
   - Distributed telemetry overview
   - Python-to-Elixir event folding
   - Event naming conventions
   - Performance considerations

2. **[01_EVENT_CATALOG.md](./01_EVENT_CATALOG.md)** - Complete event specification
   - Layer 1: Infrastructure events (Pool, Worker, Session)
   - Layer 2: Python execution events (folded from Python)
   - Layer 3: gRPC bridge events
   - Measurements vs Metadata
   - Correlation IDs for distributed tracing

3. **[02_PYTHON_INTEGRATION.md](./02_PYTHON_INTEGRATION.md)** - Python-side telemetry
   - ~~stderr-based approach~~ (superseded by gRPC)
   - Event flow examples
   - Configuration
   - Testing

4. **[03_CLIENT_GUIDE.md](./03_CLIENT_GUIDE.md)** - How clients consume telemetry
   - Attaching event handlers
   - Distributed aggregation
   - Forwarding to Prometheus, StatsD, OpenTelemetry
   - Custom metrics
   - Testing with telemetry

### Implementation Details

5. **[04_GRPC_STREAM.md](./04_GRPC_STREAM.md)** ⭐ **INITIAL IMPLEMENTATION**
   - gRPC bidirectional telemetry stream
   - Protobuf message definitions
   - Python emitter implementation
   - Elixir stream handler
   - Configuration and control

6. **[05_WORKER_BACKENDS.md](./05_WORKER_BACKENDS.md)** - Flexible backend architecture
   - Pluggable backend system
   - gRPC backend (Phase 2.1)
   - OpenTelemetry backend (Phase 2.2)
   - StatsD backend (Phase 2.3)
   - stderr fallback
   - Backend selection

---

## 🎯 Quick Start

### For Users (Consuming Telemetry)

```elixir
# Attach a simple handler
:telemetry.attach(
  "my-app-monitor",
  [:snakepit, :python, :call, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms = measurements.duration / 1_000_000
    IO.puts("Python call completed in #{duration_ms}ms")
  end,
  nil
)
```

See [03_CLIENT_GUIDE.md](./03_CLIENT_GUIDE.md) for complete integration patterns.

### For Developers (Implementing Telemetry)

**Phase 2.1 (gRPC Stream - Initial Implementation):**
1. Update protobuf definitions (see [04_GRPC_STREAM.md](./04_GRPC_STREAM.md))
2. Implement Python gRPC telemetry emitter
3. Implement Elixir gRPC stream handler
4. Wire up event folding

**Future Phases:**
- Phase 2.2: Add pluggable backend system
- Phase 2.3: OpenTelemetry integration
- Phase 2.4: Additional backends (StatsD, Prometheus)

---

## 🏗️ Architecture Summary

```
┌─────────────────────────────────────────────────────┐
│ CLIENT APPLICATION                                   │
│ :telemetry.attach([:snakepit, :python, :*], ...)   │
└─────────────────┬───────────────────────────────────┘
                  │ listens to Elixir :telemetry events
┌─────────────────▼───────────────────────────────────┐
│ SNAKEPIT TELEMETRY LAYER                             │
│ • Elixir events: Pool, Worker, Session              │
│ • Python folding: gRPC stream → :telemetry         │
│ • Distributed: Node-aware metadata                  │
└────────────┬────────────────────────────────────────┘
             │
      ┌──────┴──────┐
      │             │
┌─────▼────┐   ┌────▼──────┐
│ ELIXIR   │   │ PYTHON    │
│ Pool     │◄──┤ Telemetry │
│ Worker   │gRPC│ Emitter   │
│ Session  │   │ (gRPC)    │
└──────────┘   └───────────┘
```

---

## 🎨 Design Principles

### 1. **Elixir-Centric**
All events are Elixir `:telemetry` events, even if originating from Python. Clients have a single integration point.

### 2. **Distributed by Design**
All events include `node` in metadata for cluster-wide aggregation and debugging.

### 3. **Python Telemetry Folding**
Python workers emit telemetry that gets captured by Elixir and re-emitted as `:telemetry` events.

**Initial:** gRPC bidirectional stream (clean, efficient, structured)
**Fallback:** stderr with JSON (simple, universal)

### 4. **Zero External Dependencies**
Core telemetry uses only standard library + `:telemetry`. External integrations (Prometheus, OpenTelemetry) are optional.

### 5. **Flexible Backends**
Python workers support pluggable telemetry backends (gRPC, OpenTelemetry, StatsD, stderr) so users can choose what fits their infrastructure.

---

## 📊 Event Layers

### Layer 1: Infrastructure (Elixir)
Emitted directly by Snakepit Elixir code:
- `[:snakepit, :pool, :*]` - Pool management
- `[:snakepit, :pool, :worker, :*]` - Worker lifecycle
- `[:snakepit, :session, :*]` - Session management

### Layer 2: Python Execution (Folded)
Emitted by Python, captured and re-emitted by Elixir:
- `[:snakepit, :python, :call, :*]` - Command execution
- `[:snakepit, :python, :memory, :*]` - Resource metrics
- `[:snakepit, :python, :error, :*]` - Python errors

### Layer 3: gRPC Bridge (Elixir)
Emitted by gRPC communication layer:
- `[:snakepit, :grpc, :call, :*]` - gRPC calls
- `[:snakepit, :grpc, :stream, :*]` - Streaming
- `[:snakepit, :grpc, :connection, :*]` - Connection health

---

## 🗺️ Implementation Roadmap

### ✅ Phase 1: Core Type System (v0.6.7 - COMPLETE)
- Structured errors
- Type specifications
- JSON performance boost

### 🚧 Phase 2.1: Elementary Telemetry (THIS)
**Estimated Effort:** 2-3 weeks

**Deliverables:**
- [ ] Protobuf definitions for telemetry stream
- [ ] Python gRPC telemetry emitter
- [ ] Elixir gRPC stream handler
- [ ] Python-to-Elixir event folding
- [ ] Basic configuration system
- [ ] Unit tests for telemetry emission
- [ ] Integration tests for event flow
- [ ] Documentation and examples

**Success Criteria:**
- Python workers can emit telemetry via gRPC
- Elixir re-emits as `:telemetry` events
- Clients can attach handlers and receive events
- Correlation IDs work across boundary
- Zero performance regression

### 📅 Phase 2.2: Pluggable Backends (Future)
- Abstract telemetry backend in Python
- OpenTelemetry backend implementation
- Backend selection via configuration

### 📅 Phase 2.3: Additional Backends (Future)
- StatsD/DogStatsD backend
- Prometheus scraping support
- Custom user backends

### 📅 Phase 2.4: Advanced Features (Future)
- Dynamic sampling control
- Event filtering
- Performance dashboard templates
- Telemetry-driven testing utilities

---

## 🔍 Key Features

### Distributed Tracing
Correlation IDs flow across Elixir → Pool → Worker → gRPC → Python:

```elixir
correlation_id = UUID.uuid4()

# Flows through all events
[:snakepit, :pool, :queue, :enqueued]       # correlation_id: "abc-123"
[:snakepit, :python, :call, :start]         # correlation_id: "abc-123"
[:snakepit, :grpc, :call, :start]           # correlation_id: "abc-123"
[:snakepit, :python, :call, :stop]          # correlation_id: "abc-123"
```

### Bidirectional Control
Elixir can control Python telemetry behavior:

```elixir
# Reduce sampling for high-frequency events
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)  # 10%
```

### Flexible Integration
Clients choose how to consume:

```elixir
# Simple: Log to console
:telemetry.attach(..., &Logger.info/4, nil)

# Advanced: Forward to Prometheus
TelemetryMetricsPrometheus.init(metrics: metrics())

# Custom: Aggregate across cluster
GenServer for cluster-wide stats
```

---

## 📖 Usage Examples

### Python Worker

```python
from snakepit_bridge import telemetry

def inference(model_name: str, input_data):
    with telemetry.span("inference", {"model": model_name}):
        result = model.predict(input_data)

        telemetry.emit(
            "inference.tokens",
            {"token_count": len(result.tokens)},
            {"model": model_name}
        )

        return result
```

### Elixir Client

```elixir
:telemetry.attach(
  "inference-monitor",
  [:snakepit, :python, :inference, :stop],
  fn _event, %{duration: duration}, %{model: model}, _config ->
    duration_ms = duration / 1_000_000
    MyApp.Metrics.record_inference_duration(model, duration_ms)
  end,
  nil
)
```

---

## 🧪 Testing

Each component includes comprehensive tests:

- **Python:** `priv/python/tests/test_telemetry.py`
- **Elixir:** `test/snakepit/telemetry/*_test.exs`
- **Integration:** `test/integration/telemetry_flow_test.exs`

---

## 📚 References

- [Elixir :telemetry](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [OpenTelemetry](https://opentelemetry.io/)
- [StatsD Protocol](https://github.com/statsd/statsd/blob/master/docs/metric_types.md)
- [Prometheus](https://prometheus.io/)

---

## 💬 Questions?

This is a design document. Implementation will happen in phases as outlined above.

**Related PRs:**
- v0.6.7: Phase 1 Type System MVP (JSON performance, structured errors)
- v0.7.0: Phase 2.1 Elementary Telemetry (gRPC stream, event folding)

---

**Last Updated:** 2025-10-28
**Status:** Ready for implementation
**Next:** Protobuf definitions for telemetry stream
