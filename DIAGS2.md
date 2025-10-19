# Snakepit Architecture Diagrams (v0.6.0)  

These diagrams complement the performance view by focusing on system boundaries, supervision, state flow, and recovery paths after the worker profile and heartbeat upgrades.

## 1. High-Level System Overview

```mermaid
graph TB
    subgraph Elixir["Elixir Control Plane"]
        App["Snakepit.Application"]
        SessionStore["Bridge.SessionStore<br>GenServer + ETS"]
        ToolRegistry["Bridge.ToolRegistry<br>GenServer"]
        GRPCEndpoint["Snakepit.GRPC.Endpoint<br>Cowboy"]
        Pool["Snakepit.Pool<br>GenServer"]
        WorkerSup["WorkerSupervisor<br>DynamicSupervisor"]
        Lifecycle["Worker Lifecycle<br>Manager"]
        Cleanup["Pool.ApplicationCleanup"]
    end

    subgraph Capsule["Worker Capsule"]
        Starter["Worker.Starter<br>Supervisor"]
        Profile["WorkerProfile<br>process/thread"]
        Worker["GRPCWorker<br>GenServer"]
        Heartbeat["HeartbeatMonitor<br>GenServer"]
    end

    subgraph Python["Python Worker Process"]
        GRPCServer["grpc_server.py<br>Stateless bridge"]
        SessionCtx["SessionContext<br>TTL cache"]
        Adapter["User Adapter<br>Custom tools"]
    end

    App --> SessionStore
    App --> ToolRegistry
    App --> GRPCEndpoint
    App --> Pool
    App --> WorkerSup
    App --> Lifecycle
    App --> Cleanup

    WorkerSup --> Starter
    Starter --> Profile
    Profile --> Worker
    Worker --> Heartbeat
    Worker -->|spawn & port| GRPCServer
    GRPCServer --> SessionCtx
    SessionCtx --> Adapter
    SessionCtx -->|state ops| GRPCEndpoint
    GRPCEndpoint --> SessionStore
    Pool --> WorkerSup
    Pool --> Lifecycle
    Pool --> SessionStore
```

**Takeaways**
- Python stays stateless; all persistent data lives in the SessionStore.
- Worker capsules isolate failures so restart intensity is contained to the affected worker.
- LifecycleManager bridges runtime metrics (requests, TTLs) with supervision without blocking the hot path.

---

## 2. Supervision Tree (runtime)

```mermaid
graph LR
    Root["Snakepit.Supervisor<br>:one_for_one"]
    BaseA["Snakepit.Bridge.SessionStore"]
    BaseB["Snakepit.Bridge.ToolRegistry"]
    GRPC["GRPC.Server.Supervisor<br>Snakepit.GRPC.Endpoint"]
    TaskSup["Task.Supervisor<br>Snakepit.TaskSupervisor"]
    Reg["Snakepit.Pool.Registry"]
    StarterReg["Snakepit.Pool.Worker.StarterRegistry"]
    ProcReg["Snakepit.Pool.ProcessRegistry"]
    WorkerSup["Snakepit.Pool.WorkerSupervisor<br>DynamicSupervisor"]
    Lifecycle["Snakepit.Worker.LifecycleManager"]
    Pool["Snakepit.Pool"]
    Cleanup["Snakepit.Pool.ApplicationCleanup"]

    Root --> BaseA
    Root --> BaseB
    Root --> GRPC
    Root --> TaskSup
    Root --> Reg
    Root --> StarterReg
    Root --> ProcReg
    Root --> WorkerSup
    Root --> Lifecycle
    Root --> Pool
    Root --> Cleanup

    WorkerSup --> Starter1["Worker.Starter 1"]
    WorkerSup --> Starter2["Worker.Starter 2"]
    Starter1 --> Worker1["GRPCWorker 1"]
    Starter2 --> Worker2["GRPCWorker 2"]
    Starter1 --> HB1["HeartbeatMonitor 1"]
    Starter2 --> HB2["HeartbeatMonitor 2"]
```

**Notes**
- `Snakepit.Pool.ApplicationCleanup` is intentionally last so it terminates first, guaranteeing external processes are reaped.
- Heartbeat monitors live directly under each WorkerStarter, keeping restarts local.
- Base services (SessionStore, ToolRegistry) stay up even when pooling is disabled for tests.

---

## 3. State Management and Session Flow

```mermaid
graph LR
    subgraph PythonSide["Python (stateless)"]
        Adapter["Adapter"]
        SessionCtx["SessionContext"]
        PyClient["gRPC client stubs"]
    end

    subgraph ElixirSide["Elixir (stateful)"]
        Endpoint["Snakepit.GRPC.Endpoint"]
        SessionStore["SessionStore<br>GenServer + ETS"]
        ETS["ETS Tables<br>read/write concurrency"]
    end

    Adapter --> SessionCtx
    SessionCtx --> PyClient
    PyClient --> Endpoint
    Endpoint --> SessionStore
    SessionStore --> ETS
    ETS --> SessionStore
    SessionStore --> Endpoint
    Endpoint --> PyClient
    PyClient --> SessionCtx

    style PythonSide fill:#fffde7,stroke:#f9a825,stroke-width:2px
    style ElixirSide fill:#e8eaf6,stroke:#3949ab,stroke-width:2px
```

**Highlights**
- SessionContext caches reads with TTL to reduce round-trips but always writes through to Elixir.
- ETS tables use decentralized counters to avoid contention when thousands of requests per second hit the store.
- Cleanup routines (`select_delete`) are coordinated from the SessionStore GenServer to keep invariants intact.
- OTEL exporters span both halves of the architecture: set `config :snakepit, opentelemetry: %{enabled: true}` on the Elixir side and install the Python bridge requirements so cross-language traces/log correlation stays intact.

---

## 4. Worker Startup & Registration

```mermaid
sequenceDiagram
    participant Pool as Pool
    participant WorkerSup as WorkerSupervisor
    participant Starter as Worker.Starter
    participant Profile as WorkerProfile
    participant Worker as GRPCWorker
    participant Registry as Registries
    participant Lifecycle as LifecycleManager

    Pool->>WorkerSup: start_worker(worker_id, profile)
    WorkerSup-->>Pool: {:ok, starter_pid}
    WorkerSup->>Starter: start_child(worker_id)
    Starter->>Profile: start_worker(config)
    Profile-->>Starter: {:ok, worker_handle}
    Starter->>Worker: start_link(worker_handle, config)
    Worker->>Registry: register(worker_id, pid, os_pid)
    Worker->>Lifecycle: track(worker_id, config)
    Worker-->>Pool: {:worker_ready, worker_id}
```

**Implications**
- Worker profiles can encapsulate bespoke startup logic (process vs. thread) without leaking details to the pool.
- Lifecycle tracking begins immediately, ensuring TTL enforcement even for never-used workers.
- Registries receive both BEAM pid and OS pid, enabling deterministic cleanup on crash.

---

## 5. Failure Handling & Cleanup

```mermaid
flowchart TD
    HB[Heartbeat timeout] --> Lifecycle
    Lifecycle --> Pool
    Pool --> WorkerSup
    WorkerSup --> Starter
    Starter --> Worker
    Worker -->|terminate| ProcessKiller
    ProcessKiller --> OS["kill python process"]
    Starter --> Restart["restart new capsule"]
```

**Summary**
- Heartbeat or lifecycle signals prompt the pool to remove the worker from routing and ask the supervisor for a fresh capsule.
- `Snakepit.ProcessKiller` issues POSIX signals (TERM then KILL) so zombie Python processes do not survive restarts.
- Once cleanup finishes, the WorkerSupervisor starts a replacement and the pool re-registers it, restoring capacity.
