# Snakepit Performance Architecture Diagrams (v0.6.0)  

High-performance behaviour in Snakepit is anchored in constant-time routing, concurrent worker startup, and proactive health management. The diagrams below highlight the control-plane mechanics that keep latency low while tolerating heavy churn in external Python processes.

## Key Performance Features

- Dual worker profiles (process or thread) surfaced through the same pool API
- Non-blocking pool backed by `Task.Supervisor.async_nolink/2`
- ETS-backed registries with O(1) worker lookup and session affinity
- Heartbeat-driven failure detection feeding back into OTP supervision
- Lifecycle-driven recycling to cap memory growth and tail latency

---

## 1. Control Plane & Worker Capsule (performance focus)

```mermaid
graph TD
    subgraph ControlPlane["Elixir Control Plane"]
        Pool["Pool<br>GenServer"]
        TaskSup["Task Supervisor<br>Async execution"]
        Registries["Registries<br>Worker / Starter / Process"]
        Lifecycle["Worker Lifecycle<br>Manager"]
        GRPCServer["GRPC Endpoint<br>Cowboy + gRPC"]
        WorkerSup["Worker Supervisor<br>DynamicSupervisor"]
    end

    subgraph WorkerCapsule["Worker Capsule (per worker)"]
        Starter["Worker.Starter<br>Permanent supervisor"]
        Profile["WorkerProfile<br>process/thread"]
        Worker["GRPCWorker<br>GenServer"]
        Heartbeat["HeartbeatMonitor<br>GenServer"]
    end

    subgraph External["Python Runtime"]
        PythonProc["grpc_server.py<br>Stateless worker"]
    end

    Pool --> Registries
    Pool --> TaskSup
    WorkerSup --> Starter
    Starter --> Profile
    Profile --> Worker
    Worker --> Heartbeat
    Worker -->|Spawn & Port| PythonProc
    PythonProc -->|gRPC state ops| GRPCServer
    TaskSup -->|Execute| Worker
    Lifecycle --> Worker
    Heartbeat --> Lifecycle
    Registries --> WorkerSup

    style ControlPlane fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px,color:#000
    style WorkerCapsule fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    style External fill:#fff3e0,stroke:#ef6c00,stroke-width:2px,color:#000
    style Pool fill:#c8e6c9,color:#000
    style TaskSup fill:#c8e6c9,color:#000
    style Registries fill:#c8e6c9,color:#000
    style Lifecycle fill:#bbdefb,color:#000
    style Starter fill:#bbdefb,color:#000
    style Profile fill:#bbdefb,color:#000
    style Worker fill:#bbdefb,color:#000
    style Heartbeat fill:#bbdefb,color:#000
    style PythonProc fill:#ffe0b2,color:#000
    style GRPCServer fill:#c8e6c9,color:#000
```

**Highlights**
- Worker capsules contain all per-worker processes, so supervisor restarts are local.
- LifecycleManager tracks request budgets and TTLs to trigger proactive replacement without blocking the pool.
- HeartbeatMonitor feeds latency and timeout metrics back to LifecycleManager, enabling fast detection of wedged workers.
- OpenTelemetry spans/metrics originate in the Pool + Worker capsule layers; enable them via `config :snakepit, opentelemetry: %{enabled: true}` (Elixir) and the Python requirements listed in `priv/python/requirements.txt` for cross-language correlation.

---

## 2. Request Flow Sequence (with session affinity)

```mermaid
sequenceDiagram
    participant Client as Client
    participant Pool as Pool (GenServer)
    participant Registry as Worker Registry
    participant TaskSup as Task Supervisor
    participant Worker as GRPCWorker
    participant Python as Python Process
    participant Store as SessionStore (ETS)

    Client->>Pool: execute(command, args, session_id)
    Pool->>Registry: checkout(session_id)
    Registry-->>Pool: worker_id / nil
    alt worker available
        Pool->>TaskSup: async_nolink(request)
        TaskSup->>Worker: execute(command, args, timeout)
    else need spin-up
        Pool->>WorkerSup: start_worker()
        WorkerSup-->>Pool: {:ok, pid}
        Pool->>TaskSup: async_nolink(request)
        TaskSup->>Worker: execute(command, args, timeout)
    end

    Worker->>Python: gRPC ExecuteTool
    alt variable fetch
        Python->>Worker: gRPC GetVariable
        Worker->>Store: read(session_id, name)
        Store-->>Worker: value
        Worker-->>Python: value
    end

    Python-->>Worker: result
    Worker-->>TaskSup: {:ok, result}
    TaskSup-->>Client: reply
    TaskSup->>Pool: checkin(worker_id)
    Pool->>Lifecycle: increment_request(worker_id)
```

**Observations**
- Pool is never blocked by work execution; it immediately returns after scheduling via the Task Supervisor.
- Registry lookups and ETS-backed session reads stay O(1), keeping queue times predictable even with 100+ workers.
- LifecycleManager is notified about completed requests so TTL/request budgets stay accurate.

---

## 3. Health, Recycling, and Restart Loop

```mermaid
stateDiagram-v2
    [*] --> Booting
    Booting --> Ready: Worker registered
    Ready --> Executing: Request dispatched
    Executing --> Ready: Completion
    Ready --> HeartbeatPing: Monitor ping tick
    HeartbeatPing --> Ready: Pong in time
    HeartbeatPing --> MissedHeartbeat: Pong timeout
    MissedHeartbeat --> Ready: Pong before limit
    MissedHeartbeat --> Recycling: Max missed reached
    Ready --> Recycling: TTL reached or max requests
    Recycling --> Stopping: LifecycleManager requests stop
    Stopping --> Restarting: WorkerStarter restarts capsule
    Restarting --> Ready: Replacement live
```

**Notes**
- Heartbeat failures and lifecycle thresholds converge on the same recycling path, ensuring consistent restart semantics.
- When Recycling triggers, `Snakepit.ProcessKiller` cleans up OS processes before the supervisor brings the capsule back online.
- Restart intensity is governed by `WorkerSupervisor` limits, keeping cluster stability under heavy churn.
