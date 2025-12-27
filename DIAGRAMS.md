# Snakepit Architecture Diagrams

> Visual reference for Snakepit v0.7.2 architecture

## System Overview

```mermaid
flowchart LR
    subgraph BEAM["BEAM VM"]
        subgraph Snakepit["Snakepit.Supervisor"]
            SS[SessionStore]
            TR[ToolRegistry]
            GS[GRPC.Server]
            Pool[Pool GenServer]

            subgraph WS["WorkerSupervisor"]
                W1[Worker.Starter 1]
                W2[Worker.Starter 2]
                WN[Worker.Starter N]
            end

            PR[ProcessRegistry]
            TS[Telemetry.GrpcStream]
            AC[ApplicationCleanup]
        end
    end

    subgraph Python["Python Processes"]
        P1[grpc_server.py :50001]
        P2[grpc_server.py :50002]
        PN[grpc_server.py :500NN]
    end

    W1 --> P1
    W2 --> P2
    WN --> PN

    Pool --> WS
    PR --> P1
    PR --> P2
    PR --> PN

    P1 -.->|callbacks| GS
    P2 -.->|callbacks| GS
    PN -.->|callbacks| GS

    P1 -.->|telemetry| TS
    P2 -.->|telemetry| TS
    PN -.->|telemetry| TS

    style BEAM fill:#1e1b4b,stroke:#4f46e5,stroke-width:2px,color:#e0e7ff
    style Snakepit fill:#312e81,stroke:#6366f1,stroke-width:2px,color:#e0e7ff
    style WS fill:#4338ca,stroke:#818cf8,stroke-width:2px,color:#fff
    style Python fill:#581c87,stroke:#a855f7,stroke-width:2px,color:#f3e8ff

    style SS fill:#6366f1,stroke:#a5b4fc,color:#fff
    style TR fill:#6366f1,stroke:#a5b4fc,color:#fff
    style GS fill:#6366f1,stroke:#a5b4fc,color:#fff
    style Pool fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style PR fill:#6366f1,stroke:#a5b4fc,color:#fff
    style TS fill:#6366f1,stroke:#a5b4fc,color:#fff
    style AC fill:#6366f1,stroke:#a5b4fc,color:#fff

    style W1 fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style W2 fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style WN fill:#8b5cf6,stroke:#c4b5fd,color:#fff

    style P1 fill:#9333ea,stroke:#d8b4fe,color:#fff
    style P2 fill:#9333ea,stroke:#d8b4fe,color:#fff
    style PN fill:#9333ea,stroke:#d8b4fe,color:#fff
```

## Supervision Tree

```mermaid
flowchart LR
    S[Snakepit.Supervisor<br/>:one_for_one]

    S --> SS[SessionStore<br/>GenServer + ETS]
    S --> TR[ToolRegistry<br/>GenServer + ETS]
    S --> GSS[GRPC.Server.Supervisor]
    S --> GCS[GRPC.Client.Supervisor]
    S --> REG[Pool.Registry<br/>ETS]
    S --> PR[Pool.ProcessRegistry<br/>ETS + DETS]
    S --> WSR[Worker.StarterRegistry<br/>ETS]
    S --> TGS[Telemetry.GrpcStream<br/>GenServer]
    S --> P[Pool<br/>GenServer]
    S --> AC[ApplicationCleanup<br/>GenServer]

    P --> WS[WorkerSupervisor<br/>DynamicSupervisor]

    WS --> ST1[Worker.Starter 1<br/>Supervisor :permanent]
    WS --> ST2[Worker.Starter 2<br/>Supervisor :permanent]
    WS --> STN[Worker.Starter N<br/>Supervisor :permanent]

    ST1 --> GW1[GRPCWorker 1<br/>GenServer :transient]
    ST2 --> GW2[GRPCWorker 2<br/>GenServer :transient]
    STN --> GWN[GRPCWorker N<br/>GenServer :transient]

    style S fill:#4f46e5,color:#fff
    style P fill:#6366f1,color:#fff
    style WS fill:#8b5cf6,color:#fff
    style ST1 fill:#a78bfa,color:#000
    style ST2 fill:#a78bfa,color:#000
    style STN fill:#a78bfa,color:#000
```

## Request Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant Pool as Pool GenServer
    participant WS as WorkerSupervisor
    participant GW as GRPCWorker
    participant Py as Python Process

    App->>Pool: execute("cmd", args)

    alt Worker Available
        Pool->>Pool: Pop from :available set
        Pool->>GW: execute(cmd, args)
        GW->>Py: gRPC ExecuteTool
        Py-->>GW: ToolResult
        GW-->>Pool: {:ok, result}
        Pool->>Pool: Return to :available set
        Pool-->>App: {:ok, result}
    else No Workers Available
        Pool->>Pool: Enqueue request
        Note over Pool: Wait for worker checkin
        Pool->>GW: execute(cmd, args)
        GW->>Py: gRPC ExecuteTool
        Py-->>GW: ToolResult
        GW-->>Pool: {:ok, result}
        Pool-->>App: {:ok, result}
    end
```

## Worker Startup Sequence

```mermaid
sequenceDiagram
    participant Pool as Pool
    participant WS as WorkerSupervisor
    participant Starter as Worker.Starter
    participant GW as GRPCWorker
    participant Port as OS Port
    participant Ready as Ready File
    participant Py as Python Process

    Pool->>WS: start_worker(worker_id, config)
    WS->>Starter: start_link(worker_id)
    Starter->>GW: start_link(config)

    GW->>Port: open_port({:spawn, "python3 grpc_server.py"})
    Port->>Py: spawn process
    Py->>Py: bind to ephemeral port
    Py-->>Ready: write port (SNAKEPIT_READY_FILE)
    GW->>Ready: read port

    GW->>Py: gRPC connect to :50001
    GW->>Py: ping()
    Py-->>GW: pong

    GW->>Pool: register as available
    Pool->>Pool: Add to :available set
```

## Session Affinity Flow

```mermaid
flowchart TD
    A[execute_in_session<br/>session_id, cmd, args]

    A --> B{Session exists?}
    B -->|No| C[Create new session]
    B -->|Yes| D[Get session]

    C --> E{Any worker available?}
    D --> F{last_worker_id<br/>available?}

    F -->|Yes| G[Use preferred worker]
    F -->|No| E

    E -->|Yes| H[Pick any available worker]
    E -->|No| I[Enqueue request]

    G --> J[Execute command]
    H --> J
    I --> J

    J --> K[Update session.last_worker_id]
    K --> L[Return result]

    style A fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style B fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style C fill:#6366f1,stroke:#a5b4fc,color:#fff
    style D fill:#6366f1,stroke:#a5b4fc,color:#fff
    style E fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style F fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style G fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style H fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style I fill:#9333ea,stroke:#d8b4fe,color:#fff
    style J fill:#6366f1,stroke:#a5b4fc,color:#fff
    style K fill:#6366f1,stroke:#a5b4fc,color:#fff
    style L fill:#4f46e5,stroke:#a5b4fc,color:#fff
```

## Streaming Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant Pool as Pool
    participant GW as GRPCWorker
    participant Py as Python Worker

    App->>Pool: execute_stream(cmd, args, callback)
    Pool->>Pool: checkout_worker()
    Pool-->>App: worker_pid

    App->>GW: execute_stream(cmd, args, callback)
    GW->>Py: ExecuteStreamingTool

    loop Until is_final
        Py-->>GW: ToolChunk{data, is_final: false}
        GW->>App: callback.(chunk)
    end

    Py-->>GW: ToolChunk{data, is_final: true}
    GW->>App: callback.(final_chunk)
    GW-->>App: :ok

    App->>Pool: checkin_worker(worker_pid)
    Pool->>Pool: Return to :available set
```

## Telemetry Event Flow

```mermaid
flowchart TB
    subgraph Python["Python Worker"]
        PA[Adapter]
        TE[telemetry.emit]
        TS[TelemetryStream]
    end

    subgraph Elixir["Elixir"]
        GS[GrpcStream]
        NM[Naming]
        SM[SafeMetadata]
        TL[:telemetry]
        OT[OpenTelemetry]
        PM[Prometheus]
    end

    PA -->|event| TE
    TE -->|gRPC stream| TS
    TS -->|TelemetryEvent| GS
    GS --> NM
    NM -->|validate event| SM
    SM -->|sanitize metadata| TL
    TL --> OT
    TL --> PM

    style Python fill:#581c87,stroke:#a855f7,stroke-width:2px,color:#f3e8ff
    style Elixir fill:#312e81,stroke:#6366f1,stroke-width:2px,color:#e0e7ff

    style PA fill:#9333ea,stroke:#d8b4fe,color:#fff
    style TE fill:#9333ea,stroke:#d8b4fe,color:#fff
    style TS fill:#9333ea,stroke:#d8b4fe,color:#fff

    style GS fill:#6366f1,stroke:#a5b4fc,color:#fff
    style NM fill:#6366f1,stroke:#a5b4fc,color:#fff
    style SM fill:#6366f1,stroke:#a5b4fc,color:#fff
    style TL fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style OT fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style PM fill:#8b5cf6,stroke:#c4b5fd,color:#fff
```

## Worker Profiles

```mermaid
flowchart LR
    subgraph Process["Process Profile (Default)"]
        direction TB
        PP[Pool]
        PP --> PW1[Worker 1<br/>Python Process]
        PP --> PW2[Worker 2<br/>Python Process]
        PP --> PW3[Worker 3<br/>Python Process]

        PW1 --> PT1[1 Thread]
        PW2 --> PT2[1 Thread]
        PW3 --> PT3[1 Thread]
    end

    subgraph Thread["Thread&nbsp;Profile&nbsp;(Python&nbsp;3.13+)"]
        direction TB
        TP[Pool]
        TP --> TW1[Worker 1<br/>Python Process]
        TP --> TW2[Worker 2<br/>Python Process]

        TW1 --> TT1[Thread 1]
        TW1 --> TT2[Thread 2]
        TW1 --> TT3[Thread 3]
        TW1 --> TT4[Thread 4]

        TW2 --> TT5[Thread 1]
        TW2 --> TT6[Thread 2]
        TW2 --> TT7[Thread 3]
        TW2 --> TT8[Thread 4]
    end

    style Process fill:#312e81,stroke:#6366f1,stroke-width:2px,color:#e0e7ff
    style Thread fill:#581c87,stroke:#a855f7,stroke-width:2px,color:#f3e8ff

    style PP fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style TP fill:#7c3aed,stroke:#c4b5fd,color:#fff

    style PW1 fill:#6366f1,stroke:#a5b4fc,color:#fff
    style PW2 fill:#6366f1,stroke:#a5b4fc,color:#fff
    style PW3 fill:#6366f1,stroke:#a5b4fc,color:#fff

    style TW1 fill:#9333ea,stroke:#d8b4fe,color:#fff
    style TW2 fill:#9333ea,stroke:#d8b4fe,color:#fff

    style PT1 fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style PT2 fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style PT3 fill:#8b5cf6,stroke:#c4b5fd,color:#fff

    style TT1 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT2 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT3 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT4 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT5 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT6 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT7 fill:#a855f7,stroke:#e9d5ff,color:#fff
    style TT8 fill:#a855f7,stroke:#e9d5ff,color:#fff
```

## Heartbeat Monitoring

```mermaid
sequenceDiagram
    participant HM as HeartbeatMonitor
    participant GW as GRPCWorker
    participant Py as Python Process

    loop Every heartbeat_interval
        HM->>GW: send_heartbeat()
        GW->>Py: Heartbeat request

        alt Healthy
            Py-->>GW: HeartbeatResponse{memory_mb, uptime}
            GW-->>HM: {:ok, stats}
            HM->>HM: Reset missed_count
        else Timeout
            Note over GW,Py: No response within timeout
            HM->>HM: Increment missed_count

            alt missed_count >= max_missed
                HM->>GW: terminate (unhealthy)
                Note over GW: Supervisor restarts worker
            end
        end
    end
```

## Graceful Shutdown

```mermaid
sequenceDiagram
    participant App as Application.stop
    participant S as Supervisor
    participant AC as ApplicationCleanup
    participant Pool as Pool
    participant WS as WorkerSupervisor
    participant GW as GRPCWorker
    participant Py as Python

    App->>S: stop
    S->>AC: terminate (last child)

    par Terminate all workers
        AC->>Pool: stop
        Pool->>WS: stop
        WS->>GW: terminate
        GW->>Py: SIGTERM

        alt Graceful exit
            Py-->>GW: exit 0
        else Force kill after timeout
            GW->>Py: SIGKILL
        end
    end

    AC->>AC: Verify no orphans
    AC-->>S: :ok
```

## Error Recovery

```mermaid
flowchart TD
    E[Worker Error]

    E --> T{Error Type}

    T -->|Python crash| A[GRPCWorker receives :DOWN]
    T -->|gRPC failure| B[Connection lost]
    T -->|Timeout| C[Request timeout]

    A --> D[Worker.Starter detects child exit]
    B --> D

    D --> F{Exit reason}
    F -->|:normal| G[No restart]
    F -->|abnormal| H[Starter restarts GRPCWorker]

    H --> I[New Python process spawned]
    I --> J[gRPC connection established]
    J --> K[Worker re-registered as available]

    C --> L[Request returned with error]
    L --> M[Worker returned to available<br/>if still healthy]

    style E fill:#dc2626,stroke:#fca5a5,color:#fff
    style T fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style A fill:#9333ea,stroke:#d8b4fe,color:#fff
    style B fill:#9333ea,stroke:#d8b4fe,color:#fff
    style C fill:#f59e0b,stroke:#fcd34d,color:#000
    style D fill:#6366f1,stroke:#a5b4fc,color:#fff
    style F fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style G fill:#6b7280,stroke:#d1d5db,color:#fff
    style H fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style I fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style J fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style K fill:#22c55e,stroke:#86efac,color:#fff
    style L fill:#f59e0b,stroke:#fcd34d,color:#000
    style M fill:#6366f1,stroke:#a5b4fc,color:#fff
```

## Configuration Merge

```mermaid
flowchart TD
    A[Application Config]
    B[Pool-specific Config]
    C[Adapter Defaults]
    D[Environment Variables]

    A --> E[Config.normalize]
    B --> E
    C --> E
    D --> E

    E --> F{Simple or Multi-pool?}
    F -->|Simple| G[Convert to single-pool list]
    F -->|Multi-pool| H[Use pools list as-is]

    G --> I[Validated Config]
    H --> I

    I --> J[Pool GenServer]
    I --> K[GRPCWorker]
    I --> L[Python Environment]

    style A fill:#6366f1,stroke:#a5b4fc,color:#fff
    style B fill:#6366f1,stroke:#a5b4fc,color:#fff
    style C fill:#6366f1,stroke:#a5b4fc,color:#fff
    style D fill:#6366f1,stroke:#a5b4fc,color:#fff
    style E fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style F fill:#7c3aed,stroke:#c4b5fd,color:#fff
    style G fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style H fill:#8b5cf6,stroke:#c4b5fd,color:#fff
    style I fill:#4f46e5,stroke:#a5b4fc,color:#fff
    style J fill:#9333ea,stroke:#d8b4fe,color:#fff
    style K fill:#9333ea,stroke:#d8b4fe,color:#fff
    style L fill:#581c87,stroke:#a855f7,color:#fff
```

**Note**: Simple format (`pool_size: N, adapter_module: X`) is auto-converted to multi-pool format for internal use. Both formats are fully supported.

## Component Summary

| Component | Type | Purpose |
|-----------|------|---------|
| Snakepit.Supervisor | Supervisor | Top-level OTP supervision |
| Pool | GenServer | Request distribution, worker tracking |
| WorkerSupervisor | DynamicSupervisor | Dynamic worker management |
| Worker.Starter | Supervisor | Per-worker crash isolation |
| GRPCWorker | GenServer | Python process + gRPC connection |
| SessionStore | GenServer + ETS | Session management with TTL |
| ToolRegistry | GenServer + ETS | Bidirectional tool registration |
| ProcessRegistry | GenServer + ETS/DETS | External PID tracking |
| Telemetry.GrpcStream | GenServer | Python telemetry folding |
| ApplicationCleanup | GenServer | Shutdown guarantees |
