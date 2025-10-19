# Snakepit Supervision Tree

The diagram below captures the runtime supervision hierarchy that `Snakepit.Application` boots. Two child sets exist:

* **Base children** are always started (session store + tool registry).
* **Pooling branch** is added when `:pooling_enabled` is `true` in application config. This is the common production path.

```mermaid
flowchart TD
    A["Snakepit.Supervisor\n(strategy: one_for_one)"]
    A --> B["Snakepit.Bridge.SessionStore\n(GenServer)"]
    A --> C["Snakepit.Bridge.ToolRegistry\n(GenServer)"]

    subgraph "Pooling Enabled Branch (:pooling_enabled == true)"
        direction TB
        A --> D["GRPC.Server.Supervisor\nSnakepit.GRPC.Endpoint"]
        D --> D1["Cowboy / Ranch acceptors"]

        A --> E["Task.Supervisor\n(Snakepit.TaskSupervisor)"]
        A --> F["Snakepit.Pool.Registry\n(Registry)"]
        A --> G["Snakepit.Pool.Worker.StarterRegistry\n(Registry)"]
        A --> H["Snakepit.Pool.ProcessRegistry\n(GenServer + ETS)"]
        A --> I["Snakepit.Pool.WorkerSupervisor\n(DynamicSupervisor)"]
        A --> J["Snakepit.Worker.LifecycleManager\n(GenServer)"]
        A --> K["Snakepit.Pool\n(GenServer)\nhandles routing & scheduling"]
        A --> L["Snakepit.Pool.ApplicationCleanup\n(GenServer)\nterminates stragglers first on shutdown"]
    end

    subgraph "Pooling Disabled Branch (:pooling_enabled == false)"
        direction TB
        A --> M["(no additional supervised children)\nHandy for dev & unit tests"]
    end
```

**Notes**

- `GRPC.Server.Supervisor` encapsulates the gRPC endpoint; `Snakepit.GRPC.Endpoint` defines the service handlers.
- `Snakepit.Pool.WorkerSupervisor` dynamically supervises each `Snakepit.GRPCWorker` (and other adapter workers) under a `:one_for_one` strategy.
- `Snakepit.Pool.ProcessRegistry` tracks OS-level worker PIDs and exposes run-id based cleanup used by watchdog/process killer flows.
- `Snakepit.Pool.ApplicationCleanup` is intentionally **last** so it terminates **first**, allowing it to reap external processes before other supervisors shut down.
