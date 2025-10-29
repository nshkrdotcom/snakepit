# Snakepit Elementary Telemetry System - Design Summary

**Date:** 2025-10-28
**Status:** Design Complete - Ready for Implementation
**Total Design:** 3,764 lines across 7 documents

---

## 🎯 What We Built

A **complete, production-ready design** for distributed telemetry in Snakepit with:

✅ **gRPC bidirectional stream** as primary transport (not stderr!)
✅ **Python-to-Elixir event folding** - Python events become Elixir `:telemetry` events
✅ **Pluggable backend architecture** - Support gRPC, OpenTelemetry, StatsD, stderr
✅ **30+ event specifications** - Complete catalog of infrastructure, Python, and gRPC events
✅ **Atom-safe conversion** - Protection against atom table exhaustion
✅ **Distributed tracing** - Correlation IDs flow across Elixir/Python boundary
✅ **Zero external dependencies** - Core uses only `:telemetry` (already in deps)
✅ **Client integration guide** - Prometheus, StatsD, OpenTelemetry forwarding patterns

---

## 📚 Documentation Deliverables

### 1. **00_ARCHITECTURE.md** (481 lines)
**System overview and design principles**

Key points:
- Events flow upward to Elixir (Elixir-centric design)
- gRPC stream is primary transport (clean, bidirectional, structured)
- Three event layers: Infrastructure, Python Execution, gRPC Bridge
- Distributed awareness (node metadata in all events)
- Atom-safe conversion (Naming catalog + SafeMetadata guards)

**Critical design decision:**
```protobuf
rpc StreamTelemetry(stream TelemetryControl) returns (stream TelemetryEvent);
```
Elixir initiates and controls the stream, Python yields events.

---

### 2. **01_EVENT_CATALOG.md** (854 lines)
**Complete specification of 30+ telemetry events**

**Layer 1: Infrastructure (Elixir emits)**
- Pool: `initialized`, `status`, `queue.*`
- Worker: `spawn_started`, `spawned`, `spawn_failed`, `terminated`, `restarted`
- Session: `created`, `destroyed`, `affinity.*`

**Layer 2: Python Execution (folded from Python)**
- Call: `start`, `stop`, `exception`
- Resources: `memory.sampled`, `cpu.sampled`, `gc.completed`
- Errors: `error.occurred`

**Layer 3: gRPC Bridge (Elixir emits)**
- Call: `start`, `stop`, `exception`
- Stream: `opened`, `message`, `closed`
- Connection: `established`, `lost`, `reconnected`

Each event documented with:
- Measurements (numeric data)
- Metadata (contextual information)
- Usage examples
- Frequency/sampling recommendations

---

### 3. **02_PYTHON_INTEGRATION.md** (222 lines)
**How Python workers emit telemetry**

**High-level API:**
```python
from snakepit_bridge import telemetry

telemetry.emit("inference.start", {"system_time": ...}, {"model": "gpt-4"})

with telemetry.span("inference", {"model": "gpt-4"}):
    result = model.predict(data)
```

**Backend architecture:**
```
telemetry/__init__.py (emit, span)
    → manager.py (TelemetryManager)
        → backends/grpc.py (gRPC stream)
        → backends/stderr.py (fallback)
        → backends/otel.py (future)
```

**Key features:**
- Zero-dependency helpers (emit, span)
- Pluggable backends
- Automatic start/stop/exception events
- Configuration via environment variables

---

### 4. **03_CLIENT_GUIDE.md** (753 lines)
**How applications consume telemetry**

**Basic integration:**
```elixir
:telemetry.attach(
  "my-app",
  [:snakepit, :python, :call, :stop],
  &MyApp.handle_event/4,
  nil
)
```

**Advanced patterns:**
- Distributed aggregation (cluster-wide GenServer)
- Prometheus forwarding (TelemetryMetricsPrometheus)
- StatsD integration (TelemetryMetricsStatsd)
- OpenTelemetry integration (spans, traces)
- Custom metrics and dashboards
- Testing with telemetry

**Real-world examples:**
- DSPex integration
- Performance monitoring
- Alert triggers
- Grafana dashboards

---

### 5. **04_GRPC_STREAM.md** (481 lines) ⭐
**Implementation blueprint for Phase 2.1**

**Protobuf contract:**
```protobuf
service BridgeService {
  rpc StreamTelemetry(stream TelemetryControl) returns (stream TelemetryEvent);
}

message TelemetryEvent {
  repeated string event_parts = 1;
  map<string, TelemetryValue> measurements = 2;
  map<string, string> metadata = 3;
  int64 timestamp_ns = 4;
  string correlation_id = 5;
}
```

**Python implementation:**
- `TelemetryStream` class (async queue → gRPC)
- Integrated with `BridgeService`
- Backpressure handling (drop when full)
- Control message handling (sampling, toggle, filter)

**Elixir implementation:**
- `Snakepit.Telemetry.GrpcStream` GenServer
- Stream registration per worker
- Event translation (protobuf → `:telemetry`)
- Atom-safe conversion via `Naming` catalog

**Stream semantics:**
- Initiated by Elixir after worker connection
- Bidirectional: Elixir sends control, Python yields events
- Lifecycle tied to worker lifetime

---

### 6. **05_WORKER_BACKENDS.md** (653 lines)
**Pluggable backend architecture**

**Supported backends:**

1. **gRPC** (Phase 2.1 - Initial)
   - Default, integrated with Snakepit
   - Bidirectional control
   - Clean separation from logs

2. **OpenTelemetry** (Phase 2.2 - Future)
   - Industry standard
   - Rich ecosystem (Jaeger, Zipkin)
   - Automatic instrumentation

3. **StatsD** (Phase 2.3 - Future)
   - Simple UDP metrics
   - DogStatsD compatible
   - Fire-and-forget

4. **stderr** (Fallback)
   - Zero dependencies
   - Works with any adapter
   - Debugging/development

**Backend selection:**
```python
# Via environment variable
SNAKEPIT_TELEMETRY_BACKEND=grpc  # or otel, statsd, stderr
```

**Multi-backend support (future):**
```python
# Send to multiple backends simultaneously
composite = CompositeBackend([grpc_backend, otel_backend])
```

---

### 7. **README.md** (320 lines)
**Navigation and quick start guide**

- Documentation index
- Quick start examples (Python + Elixir)
- Architecture summary diagram
- Design principles (6 core principles)
- Implementation roadmap
- References and related PRs

---

## 🏗️ Key Architecture Decisions

### ✅ gRPC Stream (Not stderr)
**Rationale:**
- Clean separation from logs
- Binary protocol (efficient)
- Bidirectional (Elixir controls Python sampling/filtering)
- Structured (protobuf schema validation)
- Leverages existing infrastructure

### ✅ Elixir-Centric
**All telemetry events are Elixir `:telemetry` events**, even if originated from Python.

**Flow:**
```
Python worker → gRPC stream → Elixir → :telemetry.execute() → Client handlers
```

**Benefits:**
- Single integration point for clients
- Standard Elixir patterns
- Fits BEAM supervision model

### ✅ Atom-Safe Conversion
**Problem:** Python can send arbitrary strings; Elixir atom table is limited.

**Solution:**
- `Snakepit.Telemetry.Naming` - Pre-registered event catalog (atoms only)
- `Snakepit.Telemetry.SafeMetadata` - Validates/filters metadata keys
- Unknown events/keys → logged and dropped, not converted to atoms

**Protection:**
```elixir
# Python sends: "arbitrary.new.event"
# Naming.from_parts/1 returns {:error, :not_in_catalog}
# Event is dropped, not converted to atom
```

### ✅ Distributed by Design
**All events include:**
- `node: node()` - Which BEAM node emitted
- `pool_name` - Which pool
- `worker_id` - Which worker
- `correlation_id` - For distributed tracing

**Enables:**
- Cluster-wide aggregation
- Per-node debugging
- Cross-boundary tracing

### ✅ Pluggable Backends
**Python workers support multiple telemetry backends:**
- gRPC → Elixir `:telemetry` (default)
- OpenTelemetry → OTLP collectors
- StatsD → UDP metrics
- stderr → Simple fallback

**Users choose what fits their infrastructure.**

### ✅ Zero External Dependencies
**Core telemetry:**
- Elixir: Only `:telemetry` (already in deps)
- Python: Only stdlib + protobuf (already required)

**Optional integrations:**
- TelemetryMetricsPrometheus (user adds)
- OpenTelemetry SDK (user adds)
- StatsD client (user adds)

---

## 📊 Event Coverage

### 30+ Events Specified

**Infrastructure (13 events):**
- Pool management (initialized, status, queue operations)
- Worker lifecycle (spawn, terminate, restart)
- Session management (create, destroy, affinity)

**Python Execution (8 events):**
- Command execution (start, stop, exception)
- Resource metrics (memory, CPU, GC)
- Error tracking

**gRPC Bridge (9 events):**
- RPC calls (start, stop, exception)
- Streaming (open, message, close)
- Connection health (established, lost, reconnected)

**Each event includes:**
- Measurements schema
- Metadata schema
- Correlation ID support
- Frequency/sampling guidance

---

## 🔧 Implementation Readiness

### Phase 2.1 (Initial - gRPC Stream)

**Protobuf changes:**
```protobuf
service BridgeService {
  rpc StreamTelemetry(stream TelemetryControl) returns (stream TelemetryEvent);
}
```

**Python deliverables:**
- `snakepit_bridge/telemetry/stream.py` - TelemetryStream class
- `snakepit_bridge/telemetry/backends/grpc.py` - gRPC backend
- `snakepit_bridge/telemetry/backends/stderr.py` - Fallback
- Integration with `BridgeService`
- Tests

**Elixir deliverables:**
- `lib/snakepit/telemetry/grpc_stream.ex` - Stream consumer GenServer
- `lib/snakepit/telemetry/control.ex` - Control message helpers
- `lib/snakepit/telemetry/naming.ex` - Event catalog (atom safety)
- `lib/snakepit/telemetry/safe_metadata.ex` - Metadata validation
- Integration with `GRPCWorker`
- Tests

**Estimated effort:** 2-3 weeks

---

## 🎨 Usage Examples

### Python Worker Code
```python
from snakepit_bridge import telemetry

def inference(model: str, data):
    with telemetry.span("inference", {"model": model}):
        result = model.predict(data)

        telemetry.emit(
            "inference.tokens",
            {"token_count": len(result.tokens)},
            {"model": model}
        )

        return result
```

### Elixir Client Code
```elixir
:telemetry.attach(
  "my-app",
  [:snakepit, :python, :inference, :stop],
  fn _event, %{duration: d}, %{model: m}, _ ->
    duration_ms = d / 1_000_000
    Logger.info("Inference: #{m} completed in #{duration_ms}ms")
  end,
  nil
)
```

### Distributed Tracing
```elixir
# Elixir generates correlation ID
correlation_id = UUID.uuid4()
{:ok, result} = Snakepit.execute("inference", args, correlation_id: correlation_id)

# All events include same correlation_id:
# [:snakepit, :pool, :queue, :enqueued] - correlation_id: "abc-123"
# [:snakepit, :python, :call, :start] - correlation_id: "abc-123"
# [:snakepit, :grpc, :call, :start] - correlation_id: "abc-123"
# [:snakepit, :python, :inference, :start] - correlation_id: "abc-123"
# [:snakepit, :python, :inference, :stop] - correlation_id: "abc-123"
```

---

## 🛡️ Safety Features

### 1. Atom Table Protection
**Problem:** Python can send arbitrary strings → could exhaust Elixir atom table

**Solution:**
- `Naming` module: Pre-registered event catalog
- `SafeMetadata`: Validates known keys, keeps unknown as strings
- Unknown events → dropped, not converted to atoms

### 2. Backpressure Handling
**Problem:** Python produces events faster than Elixir can consume

**Solution:**
- Python: Bounded queue (1024 events), drops when full
- Elixir: Async consumer task, doesn't block worker
- Monitoring: Queue drop count exposed as metric

### 3. Never Crash on Telemetry
**Both Python and Elixir:**
```python
try:
    telemetry.emit(...)
except Exception:
    pass  # Never crash worker
```

### 4. Dynamic Control
**Elixir can adjust Python telemetry without restart:**
```elixir
# Reduce sampling for high-frequency events
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)

# Disable entirely
Snakepit.Telemetry.GrpcStream.toggle("worker_1", false)
```

---

## 🚀 Implementation Roadmap

### ✅ Phase 1: Type System MVP (v0.6.7 - COMPLETE)
- Structured errors (`Snakepit.Error`)
- Type specifications (`@spec` coverage)
- JSON performance boost (orjson - 4-6x speedup)
- **Status:** Committed and ready

### 🎯 Phase 2.1: Elementary Telemetry (NEXT)
**Estimated:** 2-3 weeks

**Deliverables:**
1. Update `priv/proto/snakepit_bridge.proto` with telemetry RPCs
2. Regenerate protobuf code (Elixir + Python)
3. Implement Python `TelemetryStream` class
4. Implement Elixir `GrpcStream` GenServer
5. Create `Naming` and `SafeMetadata` modules
6. Wire into `GRPCWorker` and `BridgeService`
7. Add configuration system
8. Write unit tests (Python + Elixir)
9. Write integration tests (end-to-end)
10. Update documentation

**Success criteria:**
- Python workers emit events via gRPC
- Elixir re-emits as `:telemetry` events
- Clients can attach handlers
- Correlation IDs work
- Atom table safe
- Zero performance regression

### 📅 Phase 2.2: Pluggable Backends (FUTURE)
- Abstract backend system
- OpenTelemetry backend
- Backend selection via config

### 📅 Phase 2.3: Additional Backends (FUTURE)
- StatsD/DogStatsD backend
- Prometheus scraping
- Multi-backend support

---

## 📐 Technical Specifications

### gRPC Stream Details

**Initiation:** Elixir opens stream after worker connects
**Direction:** Bidirectional
- Request stream: Elixir → Python (control messages)
- Response stream: Python → Elixir (telemetry events)

**Lifecycle:**
1. Worker spawns → gRPC connection established
2. Elixir calls `StreamTelemetry` → stream opens
3. Elixir sends `toggle(true)` → Python starts emitting
4. Python yields events continuously
5. Elixir sends control messages as needed (sampling, filters)
6. Worker shutdown → stream closes gracefully

**Performance:**
- Queue size: 1024 events (configurable)
- Backpressure: Drop on full (non-blocking)
- Overhead: ~100-200 bytes per event (protobuf)

### Event Naming Convention

**Format:** `[:snakepit, component, resource, action]`

**Examples:**
```elixir
[:snakepit, :pool, :worker, :spawned]
[:snakepit, :python, :call, :start]
[:snakepit, :grpc, :stream, :message]
```

**Span pattern:** Events ending in `:start`, `:stop`, `:exception`

### Measurements vs Metadata

**Measurements (numeric):**
```elixir
%{
  duration: integer(),        # Native time units
  system_time: integer(),
  queue_depth: integer(),
  memory_bytes: integer()
}
```

**Metadata (contextual):**
```elixir
%{
  node: node(),              # ALWAYS included
  pool_name: atom(),
  worker_id: String.t(),
  correlation_id: String.t(),
  command: String.t(),
  result: :success | :error
}
```

---

## 🎓 Design Patterns

### Pattern 1: Distributed Tracing
```elixir
# Generate correlation ID at entry point
correlation_id = UUID.uuid4()

# Flows through entire stack
Snakepit.execute("cmd", args, correlation_id: correlation_id)
# → [:snakepit, :pool, :*] events
# → [:snakepit, :python, :*] events
# → [:snakepit, :grpc, :*] events
# All include same correlation_id
```

### Pattern 2: Cluster Aggregation
```elixir
# GenServer collects events from all nodes
:telemetry.attach([:snakepit, :pool, :status], &ClusterMetrics.record/4, nil)

# Query cluster-wide stats
ClusterMetrics.get_total_queue_depth()
ClusterMetrics.get_workers_by_node()
```

### Pattern 3: Dynamic Sampling
```elixir
# Start with 100% sampling
# ...detect high load...
# Reduce to 10% for specific worker
Snakepit.Telemetry.GrpcStream.update_sampling("worker_1", 0.1)
```

### Pattern 4: External Forwarding
```elixir
# Forward to Prometheus
TelemetryMetricsPrometheus.init(metrics: [
  summary("snakepit.python.call.stop.duration"),
  counter("snakepit.python.call.exception.count")
])

# Or StatsD
TelemetryMetricsStatsd.start_link(metrics: metrics())
```

---

## 📋 Implementation Checklist

### Protobuf Layer
- [ ] Update `priv/proto/snakepit_bridge.proto`
- [ ] Add `TelemetryEvent`, `TelemetryValue`, `TelemetryControl` messages
- [ ] Add `StreamTelemetry` RPC to `BridgeService`
- [ ] Regenerate Elixir code (`mix grpc.gen`)
- [ ] Regenerate Python code (`priv/python/generate_grpc.sh`)

### Python Layer
- [ ] Create `snakepit_bridge/telemetry/` package
- [ ] Implement `manager.py` (TelemetryManager)
- [ ] Implement `backends/base.py` (abstract backend)
- [ ] Implement `backends/grpc.py` (gRPC backend)
- [ ] Implement `backends/stderr.py` (fallback)
- [ ] Implement `stream.py` (TelemetryStream)
- [ ] Update `grpc_server.py` to integrate telemetry
- [ ] Add tests (`test_telemetry_stream.py`, `test_telemetry_helpers.py`)

### Elixir Layer
- [ ] Create `lib/snakepit/telemetry/` directory
- [ ] Implement `grpc_stream.ex` (GenServer for stream handling)
- [ ] Implement `control.ex` (control message builders)
- [ ] Implement `naming.ex` (event catalog, atom safety)
- [ ] Implement `safe_metadata.ex` (metadata validation)
- [ ] Update `grpc_worker.ex` to register telemetry stream
- [ ] Add `Snakepit.Telemetry.TaskSupervisor` to supervision tree
- [ ] Add tests (`test/snakepit/telemetry/grpc_stream_test.exs`)

### Configuration
- [ ] Add telemetry config to `config/config.exs`
- [ ] Environment variable passthrough to Python
- [ ] Per-pool telemetry settings
- [ ] Sampling configuration

### Documentation
- [ ] Update main README with telemetry section
- [ ] Add telemetry guide to HexDocs
- [ ] Create examples (`examples/telemetry_demo.exs`)
- [ ] Document troubleshooting

---

## 🎯 Success Criteria

**Functional:**
- [ ] Python emits event → Elixir receives as `:telemetry` event
- [ ] Correlation IDs flow across boundary
- [ ] Elixir can control Python sampling dynamically
- [ ] Atom table safe (no atom exhaustion risk)
- [ ] Works across distributed cluster (multi-node)

**Non-Functional:**
- [ ] < 1% CPU overhead for telemetry at 100% sampling
- [ ] < 100ms latency from Python emit to Elixir handler
- [ ] Queue drops < 0.1% under normal load
- [ ] Zero crashes due to telemetry errors
- [ ] All 235 existing tests still pass
- [ ] No Dialyzer warnings

---

## 📊 What This Enables

### Observability
- Track Python call duration, queue depth, worker health
- Monitor memory/CPU usage from Python workers
- Detect performance regressions
- Debug distributed issues with correlation IDs

### Production Operations
- Alert on queue depth spikes
- Monitor worker restart rates
- Track error rates by type
- Capacity planning (worker utilization)

### Development
- Profile Python operations
- Find slow calls
- Debug session affinity issues
- Test telemetry-driven behavior

### Integration
- Forward to Prometheus/Grafana
- Send to Datadog/New Relic via StatsD
- Use OpenTelemetry for distributed tracing
- Custom aggregation in Elixir

---

## 🔗 Cross-References

**Related to Phase 1 (v0.6.7):**
- Structured errors (`Snakepit.Error`) work seamlessly with telemetry
- Error telemetry events include full error context
- Type specs enable better tooling for telemetry handlers

**Related to Future Work:**
- Apache Arrow integration (Phase 3) could emit serialization metrics
- MessagePack (Phase 4) could be monitored via telemetry
- Worker autoscaling could be driven by telemetry

---

## 💡 Key Insights

### 1. **Python Telemetry MUST Fold to Elixir**
Since Snakepit is an Elixir library, clients expect Elixir events. Python events are captured and re-emitted, not consumed directly.

### 2. **gRPC Stream is Natural Fit**
We already have gRPC between Elixir and Python. Adding a telemetry stream leverages existing infrastructure and provides clean separation.

### 3. **Atom Safety is Critical**
Python can send arbitrary strings. Without protection, could exhaust Elixir atom table. Event catalog + metadata validation provides safety.

### 4. **Sampling is Essential**
High-frequency events (every Python call) need sampling for production. Bidirectional gRPC stream allows dynamic control.

### 5. **Backend Flexibility Matters**
Some users want OpenTelemetry, others want StatsD, others want Elixir-only. Pluggable backends support all use cases.

---

## 📈 Next Steps

### Immediate (Phase 2.1 Implementation)
1. **Review this design** - Ensure architecture meets requirements
2. **Update protobuf** - Add telemetry RPC and messages
3. **Implement Python side** - TelemetryStream + gRPC backend
4. **Implement Elixir side** - GrpcStream GenServer + Naming catalog
5. **Write tests** - Unit + integration
6. **Verify zero regression** - All existing tests pass
7. **Benchmark overhead** - < 1% CPU for telemetry
8. **Document** - Update README, add examples

### Future Phases
- Phase 2.2: Pluggable backends (OpenTelemetry, StatsD)
- Phase 2.3: Advanced features (filtering, aggregation)
- Phase 2.4: Telemetry-driven testing utilities

---

## 📝 Files Summary

| File | Lines | Purpose |
|------|-------|---------|
| `README.md` | 320 | Navigation and overview |
| `00_ARCHITECTURE.md` | 481 | System design and principles |
| `01_EVENT_CATALOG.md` | 854 | 30+ event specifications |
| `02_PYTHON_INTEGRATION.md` | 222 | Python API and backends |
| `03_CLIENT_GUIDE.md` | 753 | Client integration patterns |
| `04_GRPC_STREAM.md` | 481 | Implementation blueprint |
| `05_WORKER_BACKENDS.md` | 653 | Backend architecture |
| **TOTAL** | **3,764** | **Complete design** |

---

## ✅ Design Status: COMPLETE

**All architectural decisions made:**
- ✅ gRPC stream as primary transport
- ✅ Python-to-Elixir folding strategy
- ✅ Atom-safe event conversion
- ✅ Pluggable backend system
- ✅ 30+ event catalog
- ✅ Client integration patterns
- ✅ Testing strategy
- ✅ Configuration approach

**Ready for:** Implementation (Phase 2.1)

**Pending:** Your approval to proceed with protobuf changes and implementation

---

**Questions?**
- Should I proceed with Phase 2.1 implementation?
- Any design changes needed before implementation?
- Should we adjust the event catalog?
- Any specific integration patterns to prioritize?
