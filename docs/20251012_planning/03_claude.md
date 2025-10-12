## 1. Distributed Consensus - Brief Reality Check

**Do you need it NOW?** **No.** You're right to push back.

### The Pragmatic Approach:

**Don't build distributed until you HAVE a distributed problem.** Here's the decision tree:

```elixir
# Single-node production (90% of users):
✅ Current ETS/DETS design is FINE
❌ Don't add Horde

# Multi-node production (10% of users):
✅ Design API to be Horde-compatible
❌ Don't bundle Horde in the lib
```

### What You Actually Need:

**Make the registry swappable via behaviour:**

```elixir
# In your lib
defmodule Snakepit.SessionStore.Adapter do
  @callback create_session(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_session(String.t()) :: {:ok, term()} | {:error, term()}
  # ... etc
end

# Default implementation (single-node)
defmodule Snakepit.SessionStore.ETS do
  @behaviour Snakepit.SessionStore.Adapter
  # Current implementation
end

# User provides (multi-node)
defmodule MyApp.SessionStore.Horde do
  @behaviour Snakepit.SessionStore.Adapter
  # Uses Horde.Registry under the hood
end

# Configuration
config :snakepit, session_adapter: Snakepit.SessionStore.ETS  # Default
# OR
config :snakepit, session_adapter: MyApp.SessionStore.Horde  # User's choice
```

**Testing:** Just test the behaviour interface with a mock adapter. **Don't test Horde itself.**

### What You Need to Know (Minimal):

1. **CAP Theorem**: Can't have Consistency + Availability + Partition-tolerance. Pick 2.
   - Single-node: CP (consistent, partition-intolerant = fine)
   - Multi-node: Usually AP (available, eventually consistent)

2. **Split-brain**: Two nodes think they're leader. Solution: Quorum (need 3+ nodes).

3. **CRDT basics**: Conflict-free data types (Horde uses these). Read one article, you're good.

**That's it.** Don't over-engineer. Document the behaviour, ship it.

---

## 2. Remaining Deep-Dive Topics (Checklist)

Copy this list to your new context:

### **A. Telemetry Architecture**
- Event taxonomy (what to emit, when)
- Metrics vs traces vs logs
- Integration patterns (Prometheus, Grafana, LiveDashboard)
- Performance overhead considerations
- Custom reporters

### **B. Chaos Testing Framework**
- Test infrastructure (Docker, multi-node)
- Failure injection techniques (SIGKILL, network partition, OOM)
- Assertion strategies (eventual consistency checks)
- CI/CD integration
- Property-based testing for edge cases

### **C. Error Handling & Propagation**
- Structured error taxonomy design
- Python→Elixir exception bridging
- Error recovery strategies
- Client-side error handling patterns
- Logging correlation IDs

### **D. Process Lifecycle (Heartbeat Pattern)**
- Implementation details (Python + Elixir)
- Timeout tuning
- Watchdog process design
- Platform differences (Linux vs macOS)
- Testing edge cases (zombie processes)

### **E. Resource Management**
- Port leak detection
- Memory profiling Python workers
- cgroups / Docker integration
- Worker recycling strategies
- Backpressure handling

### **F. Production Deployment Patterns**
- Zero-downtime upgrades
- Rolling worker replacement
- Health check endpoints
- Kubernetes integration
- Blue-green deployment

### **G. Observability Best Practices**
- Dashboard design (Grafana templates)
- Alerting rules (when to page humans)
- Distributed tracing setup
- Log aggregation (structured JSON)
- Performance profiling tools

### **H. Security Considerations**
- gRPC TLS/mTLS
- Python code sandboxing
- Resource quotas (prevent fork bombs)
- Input validation
- Secrets management

### **I. Performance Optimization**
- Pool sizing heuristics
- Worker warm-up strategies
- Connection pooling
- Serialization overhead
- gRPC tuning (HTTP/2 tweaks)

---

**Start new context with:** "Continue from topics A-I, prioritize B (Chaos Testing) and D (Heartbeat Pattern) first."

