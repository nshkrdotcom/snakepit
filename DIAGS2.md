# Snakepit Architecture Diagrams (v0.4.0+)

This document provides comprehensive Mermaid diagrams that illustrate Snakepit's system architecture, focusing on component relationships, data flow, and operational patterns. These diagrams complement the performance-focused diagrams in DIAGS.md by showing the complete system design.

## Diagram Overview

1. **High-Level System Architecture** - Component relationships and communication patterns
2. **Request Flow Sequence** - Step-by-step execution flow with session and variable management
3. **Supervision Tree** - OTP supervision hierarchy for fault tolerance
4. **State Management Flow** - How state is centralized in Elixir while Python workers remain stateless  
5. **Worker Lifecycle** - State transitions during worker lifetime
6. **Variable System Architecture** - Class structure for type-safe variable management
7. **Protocol Message Flow** - gRPC message flow between components
8. **Error Handling & Recovery** - How errors are detected and recovered from

These diagrams are essential for understanding how Snakepit achieves its design goals of high performance, fault tolerance, and clean separation of concerns.

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
        BS[BridgeServer<br/>Elixir gRPC Endpoint]
    end

    subgraph "Python Worker Process (Stateless)"
        GRPC[grpc_server.py<br/>Stateless gRPC Proxy]
        CTX[SessionContext<br/>gRPC Client to Elixir]
        ADAPTER[User Adapter]
        TOOLS[User Tools]
    end
    
    APP -->|execute| POOL
    POOL -->|manages| WS
    WS -->|supervises| STARTER
    STARTER -->|monitors| WORKER
    WORKER -->|spawns & gRPC| GRPC
    
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

This diagram shows the overall system components and their relationships. Key insights:
- **Python workers are completely stateless** - `grpc_server.py` acts as a pure proxy, forwarding all state operations (variables, sessions, programs) to the Elixir SessionStore
- **All state management happens in Elixir SessionStore** with ETS backing, enabling easy scaling and crash recovery
- **BridgeServer** is the Elixir gRPC endpoint (`Snakepit.GRPC.Endpoint`) that Python workers connect to for state operations

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

This sequence shows how variable access patterns work. Key points:
- **Python workers are stateless proxies** - All GetVariable/SetVariable calls are forwarded to Elixir's SessionStore
- **SessionContext** in Python (`session_context.py`) is a lightweight gRPC client that calls back to Elixir
- **No local state** is maintained in Python between requests, enabling crash recovery and horizontal scaling

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

The supervision tree implements the "Permanent Wrapper" pattern where Worker.Starters supervise individual workers. This decouples the Pool from worker restart logic and provides automatic recovery.

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

This diagram illustrates the key architectural principle: **stateless Python workers with centralized Elixir state**.

Implementation details:
- **Python side**: `priv/python/grpc_server.py` (stateless proxy) and `session_context.py` (gRPC client)
- **Elixir side**: `Snakepit.Bridge.SessionStore` (GenServer + ETS) and `Snakepit.GRPC.BridgeServer` (gRPC endpoint)
- **SessionContext cache** is request-scoped only - no persistent state between requests
- All state operations (get_variable, set_variable, register_variable) proxy to Elixir via gRPC

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

The worker lifecycle emphasizes fault tolerance and automatic recovery. Workers transition through well-defined states with automatic restart via the supervision tree when failures occur.

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

The variable system class diagram shows the relationship between Elixir-side storage (SessionStore) and Python-side access (SessionContext).

Key architecture points:
- **SessionStore** (`lib/snakepit/bridge/session_store.ex`) - Manages all persistent state in ETS
- **SessionContext** (`priv/python/snakepit_bridge/session_context.py`) - Lightweight gRPC client for Python adapters
- **CachedVariable** in SessionContext is request-scoped only - no persistent cache between requests
- **Type-safe variable management** across language boundaries via protobuf serialization

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

This message flow diagram shows how gRPC protobuf messages flow through the system.

Implementation files:
- **Protocol definitions**: `priv/proto/snakepit_bridge.proto`
- **Python protobuf bindings**: `priv/python/snakepit_bridge_pb2.py` and `snakepit_bridge_pb2_grpc.py`
- **Elixir protobuf bindings**: `lib/snakepit/grpc/snakepit_bridge.pb.ex`
- **Elixir BridgeServer**: `lib/snakepit/grpc/bridge_server.ex`
- **Python grpc_server**: `priv/python/grpc_server.py` (stateless proxy)

The protocol handles both tool execution and variable management through a unified gRPC interface.

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

The error handling diagram shows Snakepit's multi-layered approach to fault tolerance. Various detection mechanisms feed into recovery strategies, ensuring system resilience.

## Architecture Principles Illustrated

These diagrams demonstrate key architectural principles that make Snakepit production-ready:

1. **Stateless Workers**: Python processes hold no persistent state, enabling easy scaling
2. **Centralized State**: All session data managed in Elixir SessionStore with ETS backing
3. **Fault Tolerance**: Multi-level supervision with automatic recovery
4. **Performance**: Non-blocking operations and concurrent execution throughout
5. **Type Safety**: Structured variable system with validation and constraints
6. **Protocol Efficiency**: Modern gRPC with protobuf for reliable communication

## Rendering These Diagrams

To render these diagrams, use any tool that supports Mermaid syntax:
- **GitHub/GitLab**: Renders automatically in markdown
- **Mermaid Live Editor**: https://mermaid.live  
- **VS Code**: Install Mermaid extension
- **Documentation Tools**: MkDocs, Docusaurus, GitBook, etc.
- **ExDoc**: These diagrams are included in the generated documentation

The diagrams provide visual understanding of how Snakepit achieves its design goals of high performance, fault tolerance, and clean separation between Elixir orchestration and Python execution.