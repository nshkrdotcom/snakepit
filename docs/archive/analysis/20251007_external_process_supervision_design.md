# External Process Supervision Architecture Design

**Date**: 2025-10-07
**Context**: Snakepit Python worker process management
**Problem**: The fundamental tension between process independence and coupled lifecycle management

---

## Executive Summary

Snakepit faces an **architecturally unsolvable tension**:

**Users want BOTH**:
1. **Independence**: Python workers survive BEAM crashes (long-running ML jobs)
2. **Coupling**: Python workers die with BEAM (no orphans, clean shutdown)

**These are mutually exclusive** in a single-mode architecture.

**Solution**: Multi-mode architecture with **explicit user control** over crash/recovery semantics, integrating OS-level supervision with OTP patterns, inspired by Kubernetes, systemd, and erlexec.

---

## The Fundamental Problem

### Current Architecture (Tight but Buggy Coupling)

```
BEAM VM Process
└── Port (bidirectional communication)
    └── setsid (new process group leader)
        └── python3 grpc_server.py (PID tracked in DETS)
```

**When BEAM crashes hard (kill -9, OOM, segfault)**:
- Port doesn't send SIGTERM (no cleanup callback)
- Python process in separate group (survives)
- DETS tracking persists (finds orphans on next start)
- **Result**: Orphans accumulate (2092 DETS entries observed)

**When BEAM shuts down gracefully**:
- `GRPCWorker.terminate` sends SIGTERM
- `ApplicationCleanup` sends SIGKILL (backup)
- DETS entries cleaned
- **Result**: Clean (but multi-layer complexity)

### The Mutually Exclusive Requirements

| Requirement | Implementation | Trade-off |
|-------------|----------------|-----------|
| **No orphans ever** | Don't use `setsid`, tight Port coupling | Python dies with BEAM crashes |
| **Survive BEAM crashes** | Use `setsid`, independent process | Orphans possible |
| **Both** | ??? | Impossible without external supervisor |

---

## Industry Patterns Research

### Pattern 1: Kubernetes Sidecar (v1.28+)

**Architecture**:
```yaml
apiVersion: v1
kind: Pod
spec:
  initContainers:
  - name: python-worker-pool
    image: python:3.12
    restartPolicy: Always  # This makes it a "sidecar"
    # Starts BEFORE main container
    # Stays running
    # Gets SIGTERM before main container on shutdown

  containers:
  - name: elixir-app
    image: elixir:1.18
    # Starts AFTER sidecar ready
    # Connects to sidecar via localhost
```

**Lifecycle**:
1. Sidecar starts first
2. Main container starts
3. On shutdown: Main gets SIGTERM, then sidecar gets SIGTERM
4. Kubelet enforces grace period, then SIGKILL

**Guarantees**:
- ✅ No orphans (Kubelet kills pod atomically)
- ✅ Ordered startup/shutdown
- ⚠️ Python dies with pod (no cross-pod survival)

**Applicable to Snakepit**:
- Single-node deployment: Use systemd equivalent
- Multi-node: Actual Kubernetes pods

---

### Pattern 2: systemd Socket Activation

**Architecture**:
```ini
# python-pool.socket
[Unit]
Description=Snakepit Python Worker Pool Socket

[Socket]
ListenStream=50051
Accept=false

[Install]
WantedBy=sockets.target

# python-pool.service
[Unit]
Description=Snakepit Python Worker Pool
Requires=python-pool.socket
After=python-pool.socket

[Service]
Type=notify  # Python notifies when ready
ExecStart=/usr/bin/python3 /app/priv/python/pool_manager.py
Restart=always
NotifyAccess=main

# Graceful shutdown
KillMode=mixed  # SIGTERM to main, then SIGKILL to group
TimeoutStopSec=30
```

**Lifecycle**:
1. systemd creates socket, listening on port 50051
2. BEAM connects → systemd starts Python service
3. Python inherits socket FD from systemd
4. On BEAM crash: Python keeps running (socket stays open)
5. On system shutdown: systemd sends SIGTERM, waits, SIGKILL

**Guarantees**:
- ✅ No orphans (systemd tracks PIDs)
- ✅ Python survives BEAM crashes
- ✅ Socket activation (on-demand startup)
- ⚠️ Requires systemd (Linux only)

---

### Pattern 3: erlexec (Erlang Process Executive)

**Architecture**:
```erlang
% erlexec approach
{ok, Pid, OSPid} = exec:run(
  "python3 grpc_server.py",
  [
    {stdout, self()},
    {stderr, self()},
    {monitor, true},  % Get DOWN when process dies
    {kill_timeout, 5000},  % SIGTERM → wait 5s → SIGKILL
    {kill_group, true}  % Kill entire process group
  ]
).

% When BEAM exits
% erlexec port program (C++) ensures:
% 1. All tracked processes get SIGTERM
% 2. Wait for kill_timeout
% 3. Send SIGKILL to survivors
% 4. No orphans possible (kernel enforced)
```

**Guarantees**:
- ✅ No orphans (C++ port program handles cleanup)
- ✅ Graceful shutdown (SIGTERM first)
- ✅ Group termination (kills child processes)
- ❌ No independence (dies with BEAM)
- ✅ Works cross-platform

**How it works**:
- C++ middleware between BEAM and OS processes
- Uses `prctl(PR_SET_PDEATHSIG, SIGKILL)` on Linux
- Ensures children die when erlexec port dies
- Port dies when BEAM dies

---

### Pattern 4: supervisord (External Supervisor)

**Architecture**:
```ini
[program:snakepit-python-pool]
command=/usr/bin/python3 /app/priv/python/pool_manager.py
numprocs=10  # Start 10 workers
process_name=%(program_name)s_%(process_num)02d
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/snakepit/python-%(process_num)02d.log
```

**Lifecycle**:
1. supervisord starts Python worker pool
2. BEAM connects to existing pool via gRPC
3. On BEAM crash: Python pool continues running
4. On Python crash: supervisord restarts that worker
5. On system shutdown: supervisord stops all (SIGTERM → SIGKILL)

**Guarantees**:
- ✅ No orphans (supervisord cleans up)
- ✅ Python survives BEAM crashes
- ✅ Per-worker restart policies
- ⚠️ BEAM connects to pre-existing pool (architectural change)

---

## Requirements Matrix

| Scenario | Requirement | Current Snakepit | Desired |
|----------|-------------|------------------|---------|
| **Development** | |||
| BEAM normal shutdown | No orphans | ✅ Works | ✅ Keep |
| BEAM crash (Ctrl-C) | No orphans | ⚠️ Sometimes | ✅ Required |
| BEAM hard crash (kill -9) | Detect orphans on restart | ✅ Works | ✅ Keep |
| Developer restarts frequently | Fast cleanup | ⚠️ DETS grows | ✅ Fix |
| Running examples | Just works | ✅ Now works | ✅ Keep |
| **Production Monolith** | |||
| BEAM graceful shutdown | No orphans | ✅ Works | ✅ Keep |
| BEAM crash | No orphans | ❌ Orphans | ✅ **Critical** |
| BEAM restart (hot upgrade) | Python survives? | ❌ Dies | ⚠️ Nice-to-have |
| System restart | Clean shutdown | ✅ Via init | ✅ Keep |
| OOM kill | Orphan cleanup | ⚠️ Next start | ✅ Improve |
| **Production Distributed** | |||
| BEAM node crashes | Python on same node? | N/A | 🤔 Design needed |
| BEAM node restarts | Reconnect to Python | N/A | 🤔 Design needed |
| Python node separate | Independent lifecycle | N/A | 🤔 Design needed |
| Network partition | Orphan detection | N/A | 🤔 Design needed |
| **Long-running ML Jobs** | |||
| Training in progress | Survive BEAM restart | ❌ Dies | ✅ **Critical** |
| Model inference | Survive BEAM crash | ❌ Dies | ⚠️ Nice-to-have |
| State preservation | Persist across restarts | ❌ No | ✅ Required |

---

## Proposed Multi-Mode Architecture

### Mode 1: Coupled (Development, Simple Production)

**When to use**:
- Development
- Single-server deployments
- Short-lived operations
- Acceptable to restart Python on BEAM restarts

**Configuration**:
```elixir
# config/dev.exs
config :snakepit,
  worker_lifecycle_mode: :coupled,
  cleanup_strategy: :aggressive,
  orphan_detection: :enabled
```

**Implementation**: Current architecture + fixes
- Port-based communication
- DETS tracking for orphan detection
- Multi-layer cleanup (terminate → ApplicationCleanup → pkill)
- **Fix**: Aggressive DETS pruning

**Guarantees**:
- ✅ No orphans on graceful shutdown
- ⚠️ Orphans on hard crash, cleaned up on next start
- ❌ Python dies with BEAM

---

### Mode 2: Supervised (Production Monolith)

**When to use**:
- Production single-server
- Need guaranteed orphan cleanup
- Acceptable to use systemd/init

**Configuration**:
```elixir
# config/prod.exs
config :snakepit,
  worker_lifecycle_mode: :supervised,
  supervisor_type: :systemd,  # or :supervisord, :runit
  python_service_name: "snakepit-python-pool"
```

**Implementation**: systemd socket activation
```ini
# /etc/systemd/system/snakepit-python-pool@.service
[Unit]
Description=Snakepit Python Worker %i
BindsTo=snakepit-beam.service  # Die if BEAM dies

[Service]
Type=notify
ExecStart=/usr/bin/python3 /app/priv/python/grpc_server.py --port 5005%i
Restart=always
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

**Guarantees**:
- ✅ No orphans ever (systemd guarantees)
- ✅ Per-worker restart policies
- ✅ Survives BEAM crashes (if BindsTo not set)
- ✅ System-level monitoring

---

### Mode 3: Independent (Long-running Jobs)

**When to use**:
- ML training jobs (hours/days)
- Need to survive BEAM restarts
- State preservation required

**Configuration**:
```elixir
# config/prod.exs
config :snakepit,
  worker_lifecycle_mode: :independent,
  python_pool_strategy: :connect,  # Don't spawn, connect to existing
  python_pool_addresses: [
    "python-node-1:50051",
    "python-node-2:50052"
  ],
  heartbeat_interval: 10_000,  # Python checks BEAM alive every 10s
  heartbeat_timeout: 60_000    # Python exits if no BEAM for 60s
```

**Implementation**: Separate Python supervisor
```
[systemd]
├── snakepit-beam.service (BEAM VM)
└── snakepit-python-pool.service (Python workers)
    ├── Independent lifecycle
    ├── Heartbeat to BEAM
    └── Self-terminates if BEAM gone too long
```

**Python side**:
```python
class HealthMonitor:
    async def monitor_elixir_connection(self):
        while True:
            try:
                await self.ping_elixir()
                self.last_contact = time.time()
            except:
                if time.time() - self.last_contact > TIMEOUT:
                    logger.error("BEAM gone for 60s, self-terminating")
                    sys.exit(0)  # Triggers systemd restart
            await asyncio.sleep(10)
```

**Guarantees**:
- ✅ Survives BEAM crashes
- ✅ Eventually cleans up (heartbeat timeout)
- ✅ State can be persisted
- ⚠️ More complex deployment

---

### Mode 4: Distributed (Multi-node Production)

**When to use**:
- Distributed Elixir cluster
- Python workers on separate nodes
- Elastic scaling
- Multi-tenant isolation

**Configuration**:
```elixir
# config/prod.exs
config :snakepit,
  worker_lifecycle_mode: :distributed,
  topology: :kubernetes,  # or :nomad, :custom

  # Python workers run in separate pods/nodes
  python_discovery: :dns,  # or :consul, :etcd
  python_service_name: "snakepit-python-workers",

  # Crash behavior
  beam_crash_policy: :python_continues,  # or :python_terminates
  python_crash_policy: :beam_notified     # BEAM sees Python death via healthcheck
```

**Architecture** (Kubernetes example):
```yaml
# python-workers-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snakepit-python-workers
spec:
  replicas: 10  # Separate scaling from BEAM
  selector:
    matchLabels:
      app: snakepit-python
  template:
    spec:
      containers:
      - name: python-worker
        image: snakepit-python:latest
        ports:
        - containerPort: 50051
        livenessProbe:
          grpc:
            port: 50051
        readinessProbe:
          grpc:
            port: 50051

---
# beam-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snakepit-beam
spec:
  replicas: 3  # BEAM cluster
  template:
    spec:
      containers:
      - name: beam
        image: snakepit-beam:latest
        env:
        - name: PYTHON_WORKERS
          value: "snakepit-python-workers:50051"  # DNS service discovery
```

**Guarantees**:
- ✅ Independent scaling (Python vs BEAM)
- ✅ No orphans (Kubernetes pod lifecycle)
- ✅ Survives BEAM crashes (different pods)
- ✅ Service mesh integration (Istio, Linkerd)
- ✅ Elastic scaling
- ⚠️ Complex deployment

---

## Crash/Recovery Semantics Matrix

### Scenario: BEAM Crashes

| Mode | Python Behavior | Orphan Risk | Recovery |
|------|----------------|-------------|----------|
| **Coupled** | Dies immediately | None | Restart both |
| **Supervised** | Depends on `BindsTo` | None (systemd) | systemd decides |
| **Independent** | Continues, heartbeat timeout | Low | Reconnect or restart |
| **Distributed** | Continues | None (K8s) | BEAM reconnects |

### Scenario: Python Crashes

| Mode | BEAM Behavior | Detection | Recovery |
|------|---------------|-----------|----------|
| **Coupled** | Port DOWN message | Immediate | Supervisor restarts worker |
| **Supervised** | Health check fails | ~10s delay | systemd restarts Python |
| **Independent** | Health check fails | ~10s delay | systemd restarts, BEAM reconnects |
| **Distributed** | Health check fails | ~10s delay | K8s restarts pod, service mesh updates |

### Scenario: Network Partition

| Mode | Behavior | Detection | Recovery |
|------|----------|-----------|----------|
| **Coupled** | N/A (localhost) | N/A | N/A |
| **Supervised** | N/A (localhost) | N/A | N/A |
| **Independent** | Connection lost | Heartbeat timeout | Both self-terminate |
| **Distributed** | Partition detected | Health checks | K8s reschedules, circuit breaker |

---

## Recommended Implementation Strategy

### Phase 1: Fix Current Issues (Immediate)

**Fix DETS accumulation**:
```elixir
# In cleanup_orphaned_processes/2
# CURRENT: Only removes orphans + abandoned
entries_to_remove = old_run_orphans ++ abandoned_reservations

# FIX: Also remove confirmed-dead entries
dead_entries = all_entries
  |> Enum.filter(fn {_id, info} ->
    info.status == :active and not process_alive?(info.process_pid)
  end)

entries_to_remove = old_run_orphans ++ abandoned_reservations ++ dead_entries
```

**Add periodic DETS compaction**:
```elixir
# Every hour, remove ALL dead entries
def handle_info(:compact_dets, state) do
  compact_dets_table(state.dets_table, state.beam_run_id)
  Process.send_after(self(), :compact_dets, 3_600_000)  # 1 hour
  {:noreply, state}
end
```

---

### Phase 2: Add Mode Selection (Week 1)

**Add configuration**:
```elixir
# lib/snakepit/config.ex
defmodule Snakepit.Config do
  @type lifecycle_mode :: :coupled | :supervised | :independent | :distributed

  def get_lifecycle_mode do
    Application.get_env(:snakepit, :worker_lifecycle_mode, :coupled)
  end

  def validate_config! do
    mode = get_lifecycle_mode()

    case mode do
      :supervised ->
        unless System.find_executable("systemctl") do
          raise "Supervised mode requires systemd"
        end

      :distributed ->
        unless Node.alive?() do
          raise "Distributed mode requires distributed Erlang"
        end

      _ ->  :ok
    end
  end
end
```

**Update GRPCWorker**:
```elixir
def init(opts) do
  case Snakepit.Config.get_lifecycle_mode() do
    :coupled -> init_coupled_mode(opts)
    :supervised -> init_supervised_mode(opts)
    :independent -> init_independent_mode(opts)
    :distributed -> init_distributed_mode(opts)
  end
end

defp init_coupled_mode(opts) do
  # Current implementation: spawn Python, track in DETS
end

defp init_supervised_mode(opts) do
  # Connect to systemd-managed Python service
  # No spawning, just gRPC client connection
end

defp init_independent_mode(opts) do
  # Connect to long-running Python pool
  # Register for heartbeat
end

defp init_distributed_mode(opts) do
  # Service discovery (DNS, Consul, etc)
  # Load balancing across Python nodes
end
```

---

### Phase 3: Implement erlexec Integration (Week 2)

**Option A**: Use erlexec library directly
```elixir
# mix.exs
{:erlexec, "~> 2.0"}

# In GRPCWorker (coupled mode)
def spawn_python_with_erlexec(script, args) do
  {:ok, pid, os_pid} = :exec.run(
    [script | args],
    [
      {:stdout, self()},
      {:stderr, self()},
      {:cd, Path.dirname(script)},
      {:monitor, true},
      {:kill_timeout, 5000},
      {:kill_group, true},  # Kill process group on exit
      {:env, [{"PYTHONUNBUFFERED", "1"}]}
    ]
  )

  # erlexec GUARANTEES cleanup when BEAM dies
  {:ok, pid, os_pid}
end
```

**Guarantees**:
- ✅ **Zero orphans** (C++ port enforces)
- ✅ Works cross-platform
- ✅ Minimal code changes
- ❌ Tight coupling (no independence)

---

### Phase 4: Systemd Integration (Week 3-4)

**Create Python pool manager**:
```python
# priv/python/pool_manager.py
import systemd.daemon
import asyncio
from concurrent.futures import ProcessPoolExecutor

class PythonWorkerPool:
    def __init__(self, num_workers=10):
        self.executor = ProcessPoolExecutor(max_workers=num_workers)
        self.workers = []

    async def start(self):
        # Start gRPC server
        server = grpc.aio.server()
        add_BridgeServiceServicer_to_server(self, server)

        # Inherit socket from systemd (if available)
        import systemd.socket
        fds = systemd.socket.listen_fds()
        if fds:
            # Socket activation
            server.add_insecure_port('[::]:0', fds[0])
        else:
            # Manual port
            server.add_insecure_port('[::]:50051')

        await server.start()

        # Notify systemd we're ready
        systemd.daemon.notify('READY=1')

        await server.wait_for_termination()
```

**systemd service**:
```ini
[Unit]
Description=Snakepit Python Worker Pool
# Optional: BindsTo=snakepit-beam.service  # Die with BEAM
# Or: PartOf=snakepit.target  # Grouped lifecycle

[Service]
Type=notify
ExecStart=/usr/bin/python3 /app/priv/python/pool_manager.py --workers=10
Restart=always
RestartSec=5s

# Graceful shutdown
KillMode=mixed  # SIGTERM to main, SIGKILL to group
KillSignal=SIGTERM
TimeoutStopSec=30s

# Resource limits (prevent runaway)
MemoryMax=4G
CPUQuota=200%

[Install]
WantedBy=multi-user.target
```

**Elixir side** (supervised/independent modes):
```elixir
defmodule Snakepit.Adapters.SystemdPython do
  def init_connection(opts) do
    # Don't spawn - connect to existing service
    case Snakepit.GRPC.Client.connect("localhost:50051") do
      {:ok, channel} ->
        # Service discovery via systemd
        {:ok, channel}

      {:error, _} ->
        # Service not running - start it via systemd
        System.cmd("systemctl", ["start", "snakepit-python-pool"])
        # Wait and retry
    end
  end
end
```

---

## The Ideal Solution: Hybrid Approach

### Architecture

```
Development (coupled):
  BEAM → Port → Python
  Simple, fast, acceptable orphans

Production Monolith (supervised):
  systemd
  ├── BEAM service (independent)
  └── Python pool service (independent)
  Both can crash/restart independently

Production Distributed (distributed):
  Kubernetes
  ├── BEAM pods (StatefulSet)
  └── Python worker pods (Deployment)
  Service mesh handles discovery/routing
```

### Configuration API

```elixir
# Automatic mode selection
config :snakepit,
  worker_lifecycle_mode: :auto  # Detects environment

# Auto-detection logic:
def detect_mode do
  cond do
    # Running in Kubernetes
    System.get_env("KUBERNETES_SERVICE_HOST") ->
      :distributed

    # systemd available and in prod
    Mix.env() == :prod and System.find_executable("systemctl") ->
      :supervised

    # Development
    true ->
      :coupled
  end
end
```

---

## Implementation Roadmap

### Week 1: Immediate Fixes
- [ ] Fix DETS cleanup (remove dead entries)
- [ ] Add DETS compaction (hourly)
- [ ] Improve orphan detection logging
- [ ] Add telemetry for orphan counts

**Deliverable**: Current mode works reliably, no DETS growth

---

### Week 2: Mode Framework
- [ ] Add `lifecycle_mode` configuration
- [ ] Implement mode detection
- [ ] Refactor GRPCWorker for mode dispatch
- [ ] Add mode validation on startup

**Deliverable**: Framework for modes, coupled mode same as before

---

### Week 3: erlexec Integration (Coupled+)
- [ ] Add erlexec dependency
- [ ] Implement erlexec-based spawning (optional)
- [ ] Add config: `use_erlexec: true`
- [ ] Test zero-orphan guarantee

**Deliverable**: Coupled mode with guaranteed cleanup

---

### Week 4: Systemd Mode
- [ ] Create Python pool manager script
- [ ] Create systemd service files
- [ ] Implement connection-based adapter
- [ ] Add systemd integration docs

**Deliverable**: Supervised mode for production

---

### Week 5-6: Independent Mode
- [ ] Implement heartbeat protocol
- [ ] Python self-termination logic
- [ ] State persistence mechanism
- [ ] Long-running job support

**Deliverable**: Independent mode for ML jobs

---

### Month 2-3: Distributed Mode
- [ ] Service discovery integration
- [ ] Multi-node Python pools
- [ ] Network partition handling
- [ ] Kubernetes manifests

**Deliverable**: Full distributed deployment

---

## Decision Tree for Users

```
Do you need Python to survive BEAM crashes?
├─ No → Use :coupled mode (default, simple)
│   └─ Want guaranteed cleanup?
│       ├─ Yes → Enable erlexec
│       └─ No → Accept occasional manual pkill
│
└─ Yes → How are you deploying?
    ├─ Single server → Use :supervised mode (systemd)
    ├─ Container (Docker) → Use :supervised mode (systemd in container)
    ├─ Kubernetes → Use :distributed mode
    └─ Custom → Implement heartbeat or external supervisor
```

---

## Testing Strategy

### Mode Testing Matrix

| Mode | Test | Expected |
|------|------|----------|
| Coupled | Normal shutdown | ✅ No orphans |
| Coupled | kill -9 BEAM | ⚠️ Orphans, cleaned on restart |
| Coupled | kill -9 BEAM (erlexec) | ✅ No orphans |
| Supervised | systemctl stop beam | ✅ Python continues (no BindsTo) |
| Supervised | systemctl stop beam | ✅ Python dies (with BindsTo) |
| Supervised | kill -9 BEAM | ✅ Python continues, BEAM reconnects |
| Independent | BEAM crash | ✅ Python continues 60s, then exits |
| Independent | Python crash | ✅ BEAM detects, systemd restarts |
| Distributed | Pod eviction | ✅ K8s reschedules, service mesh routes |

---

## Comparative Analysis

### erlexec vs Current Implementation

| Feature | Current | erlexec | Winner |
|---------|---------|---------|--------|
| Orphan prevention | ⚠️ Best effort | ✅ Guaranteed | erlexec |
| Cross-platform | ✅ Yes | ✅ Yes | Tie |
| Complexity | Low | Medium | Current |
| BEAM crash handling | ⚠️ Orphans | ✅ Clean | erlexec |
| Independence possible | ⚠️ Via setsid | ❌ No | Current |
| Process groups | ⚠️ Manual | ✅ Automatic | erlexec |

**Recommendation**: **Use erlexec for coupled mode** - eliminates orphans with minimal complexity.

---

### systemd vs supervisord

| Feature | systemd | supervisord | Winner |
|---------|---------|-------------|--------|
| Platform | Linux only | Cross-platform | supervisord |
| Socket activation | ✅ Yes | ❌ No | systemd |
| Process tracking | ✅ cgroups | ⚠️ PID files | systemd |
| Integration | OS-level | User-level | systemd |
| Deployment | Standard | Requires install | systemd |
| Flexibility | Lower | Higher | supervisord |

**Recommendation**: **systemd for production Linux**, supervisord for others.

---

## Configuration Examples

### Development (Coupled + erlexec)

```elixir
# config/dev.exs
config :snakepit,
  worker_lifecycle_mode: :coupled,
  use_erlexec: true,  # Guaranteed cleanup
  orphan_detection: :enabled,
  dets_cleanup: :aggressive
```

---

### Production Monolith (Systemd Supervised)

```elixir
# config/prod.exs
config :snakepit,
  worker_lifecycle_mode: :supervised,
  supervisor_type: :systemd,
  python_service_pattern: "snakepit-python-worker@*.service",
  connection_mode: :connect,  # Don't spawn
  health_check_interval: 10_000
```

**Deployment**:
```bash
# Install services
sudo cp snakepit-python-worker@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable snakepit-python-worker@{1..10}.service
sudo systemctl start snakepit-python-worker.target

# Start BEAM
sudo systemctl start snakepit-beam.service
```

---

### Production Distributed (Kubernetes)

```elixir
# config/prod.exs
config :snakepit,
  worker_lifecycle_mode: :distributed,
  python_discovery: :dns,
  python_service_name: System.get_env("PYTHON_SERVICE") || "snakepit-python-workers",
  health_check_interval: 5_000,
  circuit_breaker: [
    failure_threshold: 5,
    timeout: 30_000
  ]
```

**Deployment**:
```bash
kubectl apply -f k8s/python-workers-deployment.yaml
kubectl apply -f k8s/beam-deployment.yaml
kubectl apply -f k8s/service.yaml
```

---

## Migration Path

### From Current → erlexec (Low Risk)

```elixir
# 1. Add dependency
{:erlexec, "~> 2.0"}

# 2. Enable via config (opt-in)
config :snakepit, use_erlexec: true

# 3. GRPCWorker checks config
if Application.get_env(:snakepit, :use_erlexec, false) do
  spawn_with_erlexec()
else
  spawn_with_port()  # Current
end

# 4. Test, validate no orphans
# 5. Make default in v0.5.0
```

**Risk**: Low (fallback to current)
**Benefit**: High (guaranteed cleanup)
**Time**: 1 week

---

### From Current → Systemd (Medium Risk)

**Prerequisites**:
- Production Linux environment
- systemd access
- Deployment automation

**Steps**:
1. Create Python pool manager
2. Create systemd service files
3. Add connection-based adapter
4. Test failover scenarios
5. Document deployment

**Risk**: Medium (new deployment model)
**Benefit**: High (production-grade)
**Time**: 3-4 weeks

---

### From Current → Kubernetes (High Complexity)

**Prerequisites**:
- K8s cluster
- Docker images
- Service mesh (optional)

**Steps**:
1. Containerize BEAM + Python separately
2. Create K8s manifests
3. Implement service discovery
4. Add health checks
5. Test pod failures

**Risk**: High (architectural change)
**Benefit**: Highest (cloud-native)
**Time**: 2-3 months

---

## Immediate Action Items

### Critical (This Week)

1. **Fix DETS cleanup** - Prevents 2092 entry accumulation
   ```elixir
   # Remove ALL dead entries, not just orphans
   ```

2. **Add DETS compaction** - Periodic full scan and cleanup
   ```elixir
   # Every hour, remove confirmed-dead entries
   ```

3. **Improve logging** - Track orphan rates
   ```elixir
   :telemetry.execute([:snakepit, :orphans, :detected], %{count: ...})
   ```

### High Priority (Next Week)

4. **Add erlexec option** - Guaranteed cleanup in coupled mode
   ```elixir
   config :snakepit, use_erlexec: true
   ```

5. **Document current limitations** - Users need to know
   ```markdown
   **Known Issue**: Hard BEAM crashes may orphan Python processes.
   Mitigation: Use erlexec or supervised mode.
   ```

### Medium Priority (Month 1)

6. **Prototype systemd mode** - For production users
7. **Create deployment guides** - systemd, Docker, K8s
8. **Add mode selection** - Let users choose coupling semantics

---

## Conclusion

**The problem you identified is fundamental**: Independence and coupling are mutually exclusive in a single architecture.

**The solution**: Multi-mode architecture with **explicit user control**.

**Immediate path forward**:
1. Fix DETS cleanup (tactical, this week)
2. Add erlexec integration (strategic, next week)
3. Design mode framework (architectural, month 1)
4. Implement systemd/K8s modes (prod-ready, months 2-3)

**Philosophy**:
- **Development**: Simple, fast, acceptable imperfection
- **Production**: Robust, explicit, user-controlled trade-offs
- **Enterprise**: Distributed, resilient, cloud-native

No single solution fits all use cases. Let users choose based on their requirements.

---

**Next Steps**:
1. Review and approve this design
2. Fix immediate DETS issue
3. Begin erlexec integration
4. Create ADR for mode selection

**Related Documents**:
- Issue #2 analysis (OTP complexity)
- Process management (current implementation)
- Systematic cleanup (refactoring plan)
