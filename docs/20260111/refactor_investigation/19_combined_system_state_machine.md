# Combined System State Machine

## Overview

This document provides system-wide state machine diagrams showing how all Snakepit components interact during key operations: startup, request handling, failure recovery, and shutdown.

---

## 1. System Startup Sequence

```mermaid
sequenceDiagram
    participant OTP as OTP Application
    participant App as Snakepit.Application
    participant TS as TaskSupervisor
    participant PS as ProcessRegistry
    participant SS as SessionStore
    participant WS as WorkerSupervisor
    participant Listener as GRPC.Listener
    participant Pool as Pool GenServer
    participant Init as Init Process
    participant Worker as GRPCWorker
    participant Py as Python Process

    OTP->>App: start(:normal, [])

    App->>App: Validate config (fail-fast)

    par Start core services
        App->>TS: Start TaskSupervisor
        App->>PS: Start ProcessRegistry
        App->>SS: Start SessionStore (ETS)
    end

    App->>Listener: Start GRPC.Listener
    Listener->>Listener: Determine mode (internal/external)
    Listener->>Listener: Start Cowboy server
    Listener->>Listener: publish_port()

    App->>WS: Start WorkerSupervisor (DynamicSupervisor)
    App->>Pool: Start Pool GenServer

    Pool->>Pool: init() - resolve configs
    Pool->>Pool: Create ETS affinity cache
    Pool-->>App: {:ok, pid, {:continue, :init}}

    Pool->>Init: spawn_link initialization

    Init->>Listener: await_ready()
    Listener-->>Init: {:ok, port_info}

    loop For each pool, for each batch
        Init->>WS: start_child(worker_spec)
        WS->>Worker: start_link(opts)
        Worker->>Worker: Bootstrap.init()
        Worker->>Py: Port.open (spawn Python)
        Py->>Py: Bind gRPC, write ready file
        Worker->>Worker: Wait for ready file
        Worker->>Worker: Connect gRPC channel
        Worker->>Pool: Report ready
        Worker-->>WS: {:ok, pid}
        WS-->>Init: {:ok, pid}
    end

    Init->>Pool: {:pool_init_complete, pools}
    Pool->>Pool: Merge state, notify waiters
    Pool->>Pool: schedule_reconcile()

    Note over App,Py: System ready to accept requests
```

---

## 2. Request Lifecycle

```mermaid
sequenceDiagram
    participant Client as Client Process
    participant Pool as Pool GenServer
    participant Dispatcher as Dispatcher
    participant State as Pool.State
    participant ETS as Affinity ETS
    participant Worker as GRPCWorker
    participant Adapter as GRPCPython
    participant Channel as gRPC Channel
    participant Py as Python Process

    Client->>Pool: execute("cmd", args, opts)
    Pool->>Pool: Set deadline from timeout

    Pool->>Dispatcher: execute(state, pool_name, cmd, args, opts, from)

    Dispatcher->>Dispatcher: Resolve pool_name
    Dispatcher->>Dispatcher: Check initialization status

    alt Has session_id
        Dispatcher->>ETS: Lookup cached affinity
        alt Cache hit
            ETS-->>Dispatcher: worker_id
        else Cache miss
            Dispatcher->>Dispatcher: Query SessionStore
            Dispatcher->>ETS: Cache result
        end
    end

    Dispatcher->>State: checkout_worker()

    alt Worker available
        State->>State: increment_worker_load()
        State->>State: Update available set
        State-->>Dispatcher: {:ok, worker_id, new_state}
    else No workers / affinity busy
        alt Queue has space
            Dispatcher->>Dispatcher: Enqueue request
            Dispatcher->>Dispatcher: Schedule queue_timeout
            Dispatcher-->>Pool: {:noreply, state}
            Note over Client: Waiting in queue...
        else Queue full
            Dispatcher-->>Pool: {:reply, {:error, :pool_saturated}}
        end
    end

    Pool->>Pool: async_with_context (preserves OTel)

    Pool->>Worker: execute(worker_id, cmd, args, opts)

    Worker->>Worker: Ensure correlation ID
    Worker->>Worker: instrument_execute()
    Worker->>Adapter: grpc_execute(connection, session, cmd, args)

    Adapter->>Channel: GRPC call
    Channel->>Py: ToolRequest protobuf
    Py->>Py: Execute tool
    Py-->>Channel: ToolResponse protobuf
    Channel-->>Adapter: {:ok, response}

    Adapter-->>Worker: {:ok, result}
    Worker->>Worker: Update stats
    Worker-->>Pool: {:ok, result}

    Pool->>Pool: checkin_worker (via cast)
    Pool->>State: decrement_worker_load()
    Pool->>Dispatcher: maybe_drive_queue()

    Pool-->>Client: {:ok, result}
```

---

## 3. Streaming Request Flow

```mermaid
sequenceDiagram
    participant Client as Client
    participant Pool as Pool
    participant Worker as GRPCWorker
    participant Adapter as GRPCPython
    participant Channel as gRPC Channel
    participant Py as Python

    Client->>Pool: execute_stream("cmd", args, callback)

    Pool->>Pool: checkout_worker_for_stream()
    Pool-->>Pool: {:ok, worker_id}

    Pool->>Worker: execute_stream(worker_id, cmd, args, callback, opts)
    Worker->>Adapter: grpc_execute_stream(connection, ...)

    Adapter->>Channel: Start streaming RPC
    Channel->>Py: StreamingToolRequest

    loop Stream chunks
        Py-->>Channel: ToolChunk
        Channel-->>Adapter: {:ok, chunk}
        Adapter->>Adapter: consume_stream()
        Adapter->>Adapter: build_payload(chunk)
        Adapter->>Client: callback.(payload)

        alt callback returns :halt
            Adapter-->>Worker: :ok (terminated early)
        else callback returns :ok
            Note over Adapter: Continue streaming
        end
    end

    Py-->>Channel: Final chunk (is_final: true)
    Channel-->>Adapter: {:ok, final_chunk}
    Adapter->>Client: callback.(final_payload)
    Adapter-->>Worker: :ok

    Worker-->>Pool: :ok

    Pool->>Pool: checkin_worker (in after block)
    Pool-->>Client: :ok
```

---

## 4. Worker Failure and Recovery

```mermaid
sequenceDiagram
    participant Pool as Pool GenServer
    participant WS as WorkerSupervisor
    participant Worker as GRPCWorker
    participant Py as Python Process
    participant Barrier as CrashBarrier
    participant Reconcile as Reconciliation

    Note over Py: Python crashes!

    Py->>Worker: {:exit_status, non-zero}
    Worker->>Worker: Log crash with output

    Worker->>Worker: terminate(reason, state)
    Worker->>Worker: Cleanup resources
    Worker-->>WS: Process exits

    WS->>WS: Note worker terminated

    Pool->>Pool: handle_info({:DOWN, ...})
    Pool->>Pool: Remove from workers list
    Pool->>Pool: Remove from available set
    Pool->>Barrier: Check if tainted

    alt Request was in-flight
        Pool->>Barrier: taint_worker(worker_id)
        Barrier->>Barrier: Track failure
        Pool->>Pool: checkout_worker_for_retry()
        Pool->>Pool: Retry on different worker
    end

    Note over Pool: Periodic reconciliation (60s)

    Reconcile->>Pool: :reconcile_pools
    Pool->>Pool: Calculate deficit
    Pool->>Pool: desired - current - starting

    alt Deficit > 0
        Pool->>WS: start_replacement_workers()
        WS->>Worker: start_link(opts)
        Worker->>Py: Spawn new Python
        Worker-->>WS: {:ok, pid}
        Worker->>Pool: {:worker_ready, worker_id}
        Pool->>Pool: Add to workers, drive queue
    end

    Note over Pool: Pool capacity restored
```

---

## 5. Graceful Shutdown Sequence

```mermaid
sequenceDiagram
    participant OTP as OTP Supervisor
    participant App as Application
    participant Pool as Pool GenServer
    participant WS as WorkerSupervisor
    participant Worker as GRPCWorker
    participant HB as HeartbeatMonitor
    participant Py as Python Process
    participant Port as Erlang Port

    OTP->>App: Application.stop()

    Note over App: Supervisor shutdown begins<br/>(reverse start order)

    OTP->>Pool: shutdown signal
    Pool->>Pool: Set trap_exit
    Pool->>Pool: terminate(reason, state)
    Pool->>Pool: Log final pool states
    Pool-->>OTP: :ok

    OTP->>WS: shutdown
    WS->>WS: Shutdown all children

    par For each worker
        WS->>Worker: shutdown
        Worker->>Worker: Receive {:EXIT, :shutdown}
        Worker->>Worker: Set shutting_down = true
        Worker->>Worker: terminate(:shutdown, state)

        Worker->>HB: GenServer.stop(:shutdown)
        HB-->>Worker: stopped

        Worker->>Py: SIGTERM via Port
        Note over Py: Python graceful shutdown<br/>(server.stop + wait_for_termination)

        alt Python exits cleanly (5s timeout)
            Py-->>Port: exit_status 143 (SIGTERM)
        else Timeout
            Worker->>Py: SIGKILL
            Py-->>Port: exit_status 137 (SIGKILL)
        end

        Worker->>Worker: Cleanup ready file
        Worker->>Worker: Disconnect gRPC channel
        Worker->>Worker: Close Port
        Worker->>Worker: Unregister from registries
        Worker-->>WS: terminated
    end

    WS-->>OTP: all workers terminated
    OTP-->>App: shutdown complete
```

---

## 6. Combined High-Level State Machine

```mermaid
stateDiagram-v2
    [*] --> Booting: Application.start()

    state Booting {
        [*] --> ConfigValidation
        ConfigValidation --> CoreServices: Config valid
        ConfigValidation --> BootFailed: Invalid config

        CoreServices --> GRPCListener: Start TaskSupervisor, Registry, SessionStore
        GRPCListener --> WorkerSupervisor: Listener ready
        WorkerSupervisor --> PoolInit: Supervisor started
    }

    BootFailed --> [*]: {:error, reason}

    state PoolInit {
        [*] --> WaitingForListener
        WaitingForListener --> SpawningWorkers: Listener ready
        SpawningWorkers --> SpawningWorkers: Batch progress
        SpawningWorkers --> Ready: All workers started
        SpawningWorkers --> PartialReady: Some workers failed
        SpawningWorkers --> InitFailed: All workers failed
    }

    PartialReady --> Running: Log warnings, continue
    Ready --> Running

    InitFailed --> [*]: {:stop, :no_workers_started}

    state Running {
        [*] --> Idle

        Idle --> Processing: Request received
        Processing --> Idle: Request complete

        Idle --> Reconciling: Timer fires
        Reconciling --> Idle: Reconciliation done

        Idle --> Recovering: Worker died
        Recovering --> Idle: Replacement started
    }

    Running --> Draining: Shutdown signal
    Draining --> Terminating: Queue empty or timeout
    Terminating --> [*]: All workers stopped
```

---

## 7. Message Flow Diagram

```mermaid
flowchart TB
    subgraph Client
        C[Client Process]
    end

    subgraph Pool_Layer
        P[Pool GenServer]
        D[Dispatcher]
        E[EventHandler]
        Q[Queue]
        S[State]
    end

    subgraph Worker_Layer
        W[GRPCWorker]
        B[Bootstrap]
        PM[ProcessManager]
    end

    subgraph gRPC_Layer
        L[Listener]
        CL[Client]
        BS[BridgeServer]
    end

    subgraph External
        PY[Python Process]
    end

    C -->|execute/3| P
    P --> D
    D --> S
    D --> Q
    P --> E

    P -->|checkout| W
    W --> CL
    CL <-->|gRPC| PY

    P -->|await_ready| L
    BS <-->|gRPC| PY
    BS -->|lookup| P

    style P fill:#f9f
    style W fill:#bbf
    style PY fill:#bfb
```

---

## 8. Timing Constraints

| Operation | Timeout | Configurable |
|-----------|---------|--------------|
| Pool startup | 120s | `startup_timeout` |
| Listener ready | 30s | `listener_await_timeout_ms` |
| Worker gRPC connect | 5 retries, ~1.5s max | Internal |
| Request execution | 300s | `timeout` option |
| Streaming execution | 600s | `timeout` option |
| Queue wait | 30s | `queue_timeout` |
| Health check interval | 30s | `health_check_interval` |
| Heartbeat interval | 10s | `ping_interval_ms` |
| Graceful shutdown | 6s | `graceful_shutdown_timeout_ms` |
| Supervisor shutdown | 8s | Derived (graceful + 2s) |
| Reconciliation interval | 60s | `reconcile_interval_ms` |

---

## 9. Error Propagation Paths

```mermaid
flowchart TD
    subgraph Errors
        E1[Config Error]
        E2[Listener Timeout]
        E3[Worker Spawn Fail]
        E4[gRPC Connect Fail]
        E5[Python Crash]
        E6[Request Timeout]
        E7[Queue Timeout]
        E8[Pool Saturated]
    end

    subgraph Handling
        H1[App fails to start]
        H2[Pool exits]
        H3[Worker not added]
        H4[Worker restart]
        H5[Retry on other worker]
        H6[Return error to client]
    end

    E1 --> H1
    E2 --> H2
    E3 --> H3
    E4 --> H4
    E5 --> H5
    E6 --> H6
    E7 --> H6
    E8 --> H6
```

---

*Generated: 2026-01-11*
*Combines analysis from Pool, GRPCWorker, and BridgeServer state machines*
