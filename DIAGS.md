I'll create several Mermaid diagrams to visualize the high-performance architecture of Snakepit, with proper quotes around all subgraph blocks.

## 1. Overall System Architecture - High Performance Overview

```mermaid
graph TB
    subgraph "Elixir/OTP Layer"
        Client["Client API"]
        Pool["Pool Manager<br/>⚡ Non-blocking async"]
        TaskSup["Task Supervisor<br/>⚡ Isolated execution"]
        
        subgraph "Worker Management"
            WorkerSup["Worker Supervisor<br/>⚡ Dynamic workers"]
            Starter1["Worker Starter 1<br/>🔄 Auto-restart"]
            Starter2["Worker Starter 2<br/>🔄 Auto-restart"]
            StarterN["Worker Starter N<br/>🔄 Auto-restart"]
            Worker1["Worker 1<br/>GenServer"]
            Worker2["Worker 2<br/>GenServer"]
            WorkerN["Worker N<br/>GenServer"]
        end
        
        subgraph "High-Performance Registries"
            Registry["Worker Registry<br/>⚡ O(1) lookups"]
            ProcReg["Process Registry<br/>⚡ PID tracking"]
            StarterReg["Starter Registry<br/>⚡ Supervisor tracking"]
        end
        
        subgraph "Session Store (ETS)"
            SessionStore["Session Store<br/>⚡ Concurrent R/W<br/>📊 Decentralized counters"]
            GlobalPrograms["Global Programs<br/>⚡ Public table access"]
        end
    end
    
    subgraph "External Processes"
        Python1["Python Process 1<br/>🐍 Port communication"]
        Python2["Python Process 2<br/>🐍 Port communication"]
        PythonN["Python Process N<br/>🐍 Port communication"]
    end
    
    Client -->|"⚡ Async call"| Pool
    Pool -->|"⚡ O(1) checkout"| Registry
    Pool -->|"🎯 Session affinity"| SessionStore
    Pool -->|"⚡ Task.async_nolink"| TaskSup
    TaskSup -->|Execute| Worker1
    TaskSup -->|Execute| Worker2
    TaskSup -->|Execute| WorkerN
    
    WorkerSup -->|Supervise| Starter1
    WorkerSup -->|Supervise| Starter2
    WorkerSup -->|Supervise| StarterN
    
    Starter1 -->|Auto-restart| Worker1
    Starter2 -->|Auto-restart| Worker2
    StarterN -->|Auto-restart| WorkerN
    
    Worker1 -->|Binary protocol<br/>4-byte frames| Python1
    Worker2 -->|Binary protocol<br/>4-byte frames| Python2
    WorkerN -->|Binary protocol<br/>4-byte frames| PythonN
    
    Worker1 -->|Register| Registry
    Worker2 -->|Register| Registry
    WorkerN -->|Register| Registry
    
    Worker1 -->|Track PID| ProcReg
    Worker2 -->|Track PID| ProcReg
    WorkerN -->|Track PID| ProcReg
    
    style Pool fill:#f9f,stroke:#333,stroke-width:4px,color:#000
    style SessionStore fill:#bbf,stroke:#333,stroke-width:4px,color:#000
    style Registry fill:#bfb,stroke:#333,stroke-width:4px,color:#000
    style TaskSup fill:#fbf,stroke:#333,stroke-width:4px,color:#000
```

## 2. Request Flow - Performance Critical Path

```mermaid
sequenceDiagram
    participant C as Client
    participant P as Pool<br/>⚡ Non-blocking
    participant TS as TaskSupervisor<br/>⚡ Isolated
    participant R as Registry<br/>⚡ O(1)
    participant S as SessionStore<br/>⚡ ETS
    participant W as Worker
    participant E as External Process
    
    C->>P: execute(command, args)
    
    alt Session-based request
        P->>S: get_preferred_worker<br/>⚡ O(1) ETS lookup
        S-->>P: worker_id or nil
    end
    
    P->>R: checkout_worker<br/>⚡ O(1) via Registry
    R-->>P: worker_id
    
    P->>TS: Task.async_nolink<br/>⚡ Non-blocking
    Note over P: Pool returns immediately<br/>to handle next request
    
    TS->>W: GenServer.call
    W->>E: Port.command<br/>⚡ Binary protocol
    E-->>W: Response<br/>⚡ 4-byte framed
    W-->>TS: Result
    TS-->>C: GenServer.reply<br/>⚡ Direct to client
    
    TS->>P: checkin_worker<br/>⚡ Cast (async)
    
    alt Queued requests exist
        P->>P: Process next<br/>from queue
    else No queued requests
        P->>R: Mark available<br/>⚡ O(1) update
    end
```

## 3. ETS Tables Architecture - High Performance Storage

```mermaid
graph LR
    subgraph "Session Store ETS Tables"
        subgraph "Sessions Table"
            ST[":snakepit_sessions<br/>⚡ read_concurrency: true<br/>⚡ write_concurrency: true<br/>⚡ decentralized_counters: true"]
            
            S1["Key: session_1<br/>Value: {last_accessed, ttl, session_data}"]
            S2["Key: session_2<br/>Value: {last_accessed, ttl, session_data}"]
            SN["Key: session_N<br/>Value: {last_accessed, ttl, session_data}"]
        end
        
        subgraph "Global Programs Table"
            GP[":snakepit_sessions_global_programs<br/>⚡ Same optimizations"]
            
            P1["Key: program_1<br/>Value: {data, timestamp}"]
            P2["Key: program_2<br/>Value: {data, timestamp}"]
            PN["Key: program_N<br/>Value: {data, timestamp}"]
        end
    end
    
    subgraph "Optimized Operations"
        Read["⚡ Concurrent reads<br/>No locking"]
        Write["⚡ Concurrent writes<br/>Decentralized counters"]
        Cleanup["⚡ select_delete<br/>Atomic batch cleanup"]
    end
    
    ST --> S1
    ST --> S2
    ST --> SN
    
    GP --> P1
    GP --> P2
    GP --> PN
    
    Read --> ST
    Read --> GP
    Write --> ST
    Write --> GP
    Cleanup --> ST
    Cleanup --> GP
    
    style ST fill:#bbf,stroke:#333,stroke-width:4px,color:#000
    style GP fill:#bbf,stroke:#333,stroke-width:4px,color:#000
    style Read fill:#bfb,stroke:#333,stroke-width:2px,color:#000
    style Write fill:#bfb,stroke:#333,stroke-width:2px,color:#000
    style Cleanup fill:#fbb,stroke:#333,stroke-width:2px,color:#000
```

## 4. Worker Lifecycle - Performance & Reliability

```mermaid
stateDiagram-v2
    [*] --> Starting: Pool requests worker
    
    Starting --> Initializing: Port opened<br/>⚡ Parallel startup
    
    Initializing --> Ready: Init ping OK<br/>📊 Telemetry emitted
    Initializing --> Failed: Timeout/Error
    
    Ready --> Busy: Request received<br/>⚡ O(1) checkout
    Busy --> Ready: Response sent<br/>⚡ O(1) checkin
    
    Ready --> HealthCheck: Periodic check<br/>⏱️ Every 30s
    HealthCheck --> Ready: Healthy
    HealthCheck --> Unhealthy: Failed
    
    Unhealthy --> Restarting: Supervisor detects
    Failed --> Restarting: Auto-restart
    
    Restarting --> Starting: ♻️ Via Starter
    
    Ready --> Terminating: Shutdown signal
    Busy --> Terminating: Graceful shutdown
    
    Terminating --> [*]: Process cleaned up
    
    note right of Ready
        ⚡ Worker pool maintains
        hot workers ready for
        immediate use
    end note
    
    note right of Busy
        ⚡ Non-blocking async
        execution via Task
        Supervisor
    end note
```

## 5. Concurrent Initialization Performance

```mermaid
graph TD
    subgraph "Sequential Startup (Traditional)"
        T0["Start"] --> W1S["Worker 1<br/>2s"]
        W1S --> W2S["Worker 2<br/>2s"]
        W2S --> W3S["Worker 3<br/>2s"]
        W3S --> W4S["Worker 4<br/>2s"]
        W4S --> DoneS["Ready<br/>Total: 8s"]
    end
    
    subgraph "Concurrent Startup (Snakepit)"
        T0C["Start"] --> Init["Task.async_stream"]
        Init --> W1C["Worker 1<br/>2s"]
        Init --> W2C["Worker 2<br/>2s"]
        Init --> W3C["Worker 3<br/>2s"]
        Init --> W4C["Worker 4<br/>2s"]
        
        W1C --> Collect
        W2C --> Collect
        W3C --> Collect
        W4C --> Collect
        
        Collect --> DoneC["Ready<br/>Total: ~2s"]
    end
    
    style Init fill:#f9f,stroke:#333,stroke-width:4px,color:#000
    style DoneC fill:#bfb,stroke:#333,stroke-width:4px,color:#000
    style DoneS fill:#fbb,stroke:#333,stroke-width:2px,color:#000
```

## 6. Request Queueing & Load Distribution

```mermaid
graph TB
    subgraph "High-Performance Request Handling"
        subgraph "Request Queue"
            Q[":queue (Erlang)<br/>⚡ FIFO<br/>⚡ O(1) operations"]
            R1["Request 1"]
            R2["Request 2"]
            R3["Request 3"]
            RN["Request N"]
        end
        
        subgraph "Worker Pool State"
            Available["MapSet<br/>⚡ O(1) member check<br/>⚡ O(1) add/remove"]
            Busy["Map<br/>⚡ O(1) lookup"]
            
            AW1["Worker 1"]
            AW2["Worker 2"]
            BW3["Worker 3 🔴"]
            BW4["Worker 4 🔴"]
        end
        
        subgraph "Load Distribution"
            Check{"Worker<br/>Available?"}
            Assign["Assign to worker<br/>⚡ O(1)"]
            Queue["Queue request<br/>⚡ O(1)"]
            Dequeue["Process from queue<br/>⚡ O(1)"]
        end
    end
    
    R1 --> Check
    R2 --> Check
    R3 --> Check
    RN --> Check
    
    Check -->|Yes| Assign
    Check -->|No| Queue
    
    Queue --> Q
    Q --> Dequeue
    
    Assign --> Available
    Available --> AW1
    Available --> AW2
    
    Busy --> BW3
    Busy --> BW4
    
    Dequeue -->|Worker freed| Assign
    
    style Q fill:#bbf,stroke:#333,stroke-width:4px,color:#000
    style Available fill:#bfb,stroke:#333,stroke-width:4px,color:#000
    style Check fill:#f9f,stroke:#333,stroke-width:4px,color:#000
```

## 7. Process Registry - O(1) Performance

```mermaid
graph LR
    subgraph "Registry Architecture"
        subgraph "Worker Registry"
            WR["Elixir Registry<br/>⚡ :unique keys<br/>⚡ O(1) operations"]
            WK1["worker_1 → PID1"]
            WK2["worker_2 → PID2"]
            WKN["worker_N → PIDN"]
        end
        
        subgraph "Process Registry (ETS)"
            PR["Process Registry<br/>⚡ :protected table<br/>⚡ read_concurrency"]
            PK1["worker_1 → {pid, os_pid, fingerprint}"]
            PK2["worker_2 → {pid, os_pid, fingerprint}"]
            PKN["worker_N → {pid, os_pid, fingerprint}"]
        end
        
        subgraph "Starter Registry"
            SR["Starter Registry<br/>⚡ Supervisor tracking"]
            SK1["worker_1 → Starter PID1"]
            SK2["worker_2 → Starter PID2"]
            SKN["worker_N → Starter PIDN"]
        end
    end
    
    subgraph "O(1) Operations"
        Op1["via_tuple lookup<br/>⚡ Direct to worker"]
        Op2["Reverse lookup<br/>⚡ PID to worker_id"]
        Op3["OS PID tracking<br/>⚡ Cleanup guarantee"]
    end
    
    WR --> WK1
    WR --> WK2
    WR --> WKN
    
    PR --> PK1
    PR --> PK2
    PR --> PKN
    
    SR --> SK1
    SR --> SK2
    SR --> SKN
    
    Op1 --> WR
    Op2 --> WR
    Op3 --> PR
    
    style WR fill:#bfb,stroke:#333,stroke-width:4px,color:#000
    style PR fill:#bbf,stroke:#333,stroke-width:4px,color:#000
    style SR fill:#fbf,stroke:#333,stroke-width:4px,color:#000
```

These diagrams highlight the key performance features of Snakepit:

1. **Concurrent Operations**: Worker initialization, request handling, and cleanup all leverage Elixir's concurrent capabilities
2. **O(1) Lookups**: Registry and ETS tables provide constant-time operations for worker management
3. **Non-blocking Architecture**: The pool never blocks on worker operations thanks to Task.Supervisor
4. **Optimized Storage**: ETS tables with read/write concurrency and decentralized counters
5. **Efficient Protocols**: Binary communication with 4-byte framing for fast message parsing
6. **Auto-scaling**: Queue management with configurable limits and timeouts
7. **Zero-downtime Recovery**: Automatic worker restart without pool disruption

The architecture achieves high performance through careful use of OTP primitives and avoiding bottlenecks in the critical path.