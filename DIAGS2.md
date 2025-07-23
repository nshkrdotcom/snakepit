# Snakepit Architecture Diagrams

## 1. High-Level System Architecture

```mermaid
graph TB
    subgraph "Elixir Application"
        APP[Application Code]
        POOL[Pool<br/>GenServer]
        WS[WorkerSupervisor<br/>DynamicSupervisor]
        STARTER[Worker.Starter<br/>Supervisor]
        WORKER[GRPCWorker<br/>GenServer]
        SS[SessionStore<br/>GenServer + ETS]
        BS[BridgeServer<br/>gRPC Service]
    end
    
    subgraph "Python Worker Process"
        PORT[Port]
        GRPC[grpc_server.py<br/>gRPC Service]
        CTX[SessionContext<br/>Cache + Client]
        ADAPTER[User Adapter]
        TOOLS[User Tools]
    end
    
    APP -->|execute| POOL
    POOL -->|manages| WS
    WS -->|supervises| STARTER
    STARTER -->|monitors| WORKER
    WORKER -->|spawns| PORT
    WORKER -->|gRPC| GRPC
    PORT -.->|stdio| GRPC
    
    POOL -->|session ops| SS
    SS -->|stores state| ETS[(ETS Table)]
    
    GRPC -->|variable ops| BS
    BS -->|reads/writes| SS
    
    GRPC -->|creates| CTX
    CTX -->|gRPC callbacks| BS
    ADAPTER -->|uses| CTX
    TOOLS -->|registered in| ADAPTER
    
    style APP fill:#e1f5fe
    style POOL fill:#b3e5fc
    style SS fill:#81d4fa
    style GRPC fill:#fff9c4
    style CTX fill:#fff59d
```

## 2. Request Flow Sequence

```mermaid
sequenceDiagram
    participant App as Elixir App
    participant Pool
    participant Worker as GRPCWorker
    participant Python as Python Process
    participant Store as SessionStore
    
    App->>Pool: execute(command, args, session_id)
    Pool->>Pool: Find worker with session affinity
    Pool->>Worker: Forward request
    Worker->>Python: gRPC ExecuteTool
    
    alt Variable Access Needed
        Python->>Worker: gRPC GetVariable
        Worker->>Store: get_variable(session_id, name)
        Store-->>Worker: Variable data
        Worker-->>Python: Variable value
    end
    
    Python->>Python: Execute tool/adapter logic
    
    alt Variable Update Needed
        Python->>Worker: gRPC SetVariable
        Worker->>Store: update_variable(session_id, name, value)
        Store-->>Worker: Success
        Worker-->>Python: Confirmation
    end
    
    Python-->>Worker: Execution result
    Worker-->>Pool: Result
    Pool-->>App: Result
```

## 3. Supervision Tree

```mermaid
graph TD
    APP[Application]
    SUP[Main Supervisor]
    REG[Registries<br/>Pool.Registry<br/>ProcessRegistry<br/>StarterRegistry]
    SS[SessionStore]
    BS[BridgeServer]
    WS[WorkerSupervisor<br/>:one_for_one]
    POOL[Pool]
    CLEANUP[ApplicationCleanup]
    
    APP -->|starts| SUP
    SUP -->|permanent| REG
    SUP -->|permanent| SS
    SUP -->|permanent| BS
    SUP -->|permanent| WS
    SUP -->|permanent| POOL
    SUP -->|permanent| CLEANUP
    
    WS -->|dynamic| S1[Worker.Starter 1<br/>:permanent]
    WS -->|dynamic| S2[Worker.Starter 2<br/>:permanent]
    WS -->|dynamic| SN[Worker.Starter N<br/>:permanent]
    
    S1 -->|transient| W1[GRPCWorker 1]
    S2 -->|transient| W2[GRPCWorker 2]
    SN -->|transient| WN[GRPCWorker N]
    
    style SUP fill:#ff9800
    style WS fill:#ff9800
    style S1 fill:#ffc107
    style S2 fill:#ffc107
    style SN fill:#ffc107
```

## 4. State Management Flow

```mermaid
graph LR
    subgraph "Python Side (Stateless)"
        PY[Python Worker]
        CACHE[SessionContext<br/>Local Cache]
    end
    
    subgraph "Elixir Side (Stateful)"
        BS[BridgeServer]
        SS[SessionStore]
        ETS[(ETS Table<br/>:read_concurrency)]
    end
    
    PY -->|"get_variable<br/>set_variable<br/>register_variable"| BS
    BS -->|GenServer calls| SS
    SS -->|atomic ops| ETS
    
    CACHE -.->|"TTL-based<br/>invalidation"| CACHE
    PY -->|"cache miss"| BS
    BS -->|"variable data"| PY
    PY -->|"cache hit"| CACHE
    
    style PY fill:#fff9c4
    style CACHE fill:#fff59d
    style SS fill:#81d4fa
    style ETS fill:#4fc3f7
```

## 5. Worker Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Starting: Pool requests worker
    Starting --> Spawning: WorkerSupervisor starts Starter
    Spawning --> Launching: Starter starts GRPCWorker
    Launching --> Connecting: GRPCWorker spawns Python
    Connecting --> Ready: gRPC connection established
    
    Ready --> Executing: Receive request
    Executing --> Ready: Complete request
    
    Ready --> HealthCheck: Periodic check
    HealthCheck --> Ready: Healthy
    HealthCheck --> Reconnecting: Unhealthy
    
    Reconnecting --> Ready: Reconnected
    Reconnecting --> Crashed: Failed
    
    Ready --> Stopping: Shutdown request
    Executing --> Crashed: Error
    
    Crashed --> Restarting: Starter detects
    Restarting --> Launching: Automatic restart
    
    Stopping --> [*]: Clean shutdown
```

## 6. Variable System Architecture

```mermaid
classDiagram
    class SessionStore {
        +create_session(id, opts)
        +get_session(id)
        +delete_session(id)
        +register_variable(session_id, name, type, value)
        +get_variable(session_id, name)
        +update_variable(session_id, name, value)
        +list_variables(session_id)
        -cleanup_expired_sessions()
    }
    
    class Session {
        +id: String
        +variables: Map
        +variable_index: Map
        +programs: Map
        +metadata: Map
        +ttl: Integer
        +created_at: Integer
        +last_accessed: Integer
    }
    
    class Variable {
        +id: String
        +name: String
        +type: atom
        +value: Any
        +constraints: Map
        +metadata: Map
        +created_at: Integer
        +updated_at: Integer
    }
    
    class SessionContext {
        +session_id: String
        +stub: BridgeServiceStub
        +strict_mode: bool
        -_cache: Dict
        +register_variable(name, type, value)
        +get_variable(name)
        +update_variable(name, value)
        +__getitem__(name)
        +__setitem__(name, value)
    }
    
    class CachedVariable {
        +variable: Variable
        +cached_at: datetime
        +ttl: timedelta
        +expired: bool
    }
    
    SessionStore "1" --> "*" Session : manages
    Session "1" --> "*" Variable : contains
    SessionContext "1" --> "*" CachedVariable : caches
    SessionContext --> SessionStore : gRPC calls
```

## 7. Protocol Message Flow

```mermaid
graph TB
    subgraph "Client Request"
        REQ[ExecuteToolRequest<br/>tool_name, args, session_id]
    end
    
    subgraph "Python Processing"
        TOOL[Tool Execution]
        VAR_GET[GetVariableRequest]
        VAR_SET[SetVariableRequest]
    end
    
    subgraph "Elixir Processing"
        STORE[SessionStore Operations]
        SER[Serialization Module]
    end
    
    subgraph "Response"
        RESP[ExecuteToolResponse<br/>success, result, error]
    end
    
    REQ -->|protobuf| TOOL
    TOOL -->|need variable| VAR_GET
    VAR_GET -->|protobuf| STORE
    STORE -->|Variable| SER
    SER -->|GetVariableResponse| TOOL
    
    TOOL -->|update variable| VAR_SET
    VAR_SET -->|protobuf| STORE
    STORE -->|update| SER
    SER -->|SetVariableResponse| TOOL
    
    TOOL -->|complete| RESP
    
    style REQ fill:#e8f5e9
    style RESP fill:#e8f5e9
    style TOOL fill:#fff9c4
    style STORE fill:#81d4fa
```

## 8. Error Handling & Recovery

```mermaid
graph TD
    subgraph "Error Sources"
        E1[Python Crash]
        E2[gRPC Timeout]
        E3[Network Error]
        E4[Tool Exception]
    end
    
    subgraph "Detection"
        MON[Process Monitor]
        HC[Health Check]
        TO[Timeout Handler]
        EH[Error Handler]
    end
    
    subgraph "Recovery"
        RS[Restart Worker]
        RQ[Requeue Request]
        CB[Circuit Breaker]
        LOG[Error Logging]
    end
    
    E1 -->|:DOWN message| MON
    E2 -->|catch :exit| TO
    E3 -->|gRPC error| EH
    E4 -->|try/except| EH
    
    MON -->|Worker.Starter| RS
    HC -->|failed check| RS
    TO -->|Pool handler| RQ
    EH -->|grpc_error_handler| LOG
    
    RS -->|automatic| OK[Healthy Worker]
    RQ -->|retry logic| OK
    CB -->|threshold| FAIL[Mark Unavailable]
    
    style E1 fill:#ffcdd2
    style E2 fill:#ffcdd2
    style E3 fill:#ffcdd2
    style E4 fill:#ffcdd2
    style OK fill:#c8e6c9
```

## Usage Notes

These diagrams illustrate:

1. **System Architecture**: The overall structure and component relationships
2. **Request Flow**: How a request moves through the system
3. **Supervision Tree**: OTP supervision hierarchy for fault tolerance
4. **State Management**: How state is centralized in Elixir
5. **Worker Lifecycle**: States a worker goes through
6. **Variable System**: Class structure for variable management
7. **Protocol Flow**: How gRPC messages flow between components
8. **Error Handling**: How errors are detected and recovered from

To render these diagrams, use any tool that supports Mermaid syntax, such as:
- GitHub/GitLab (renders automatically in markdown)
- Mermaid Live Editor (https://mermaid.live)
- VS Code with Mermaid extension
- Many documentation tools (MkDocs, Docusaurus, etc.)