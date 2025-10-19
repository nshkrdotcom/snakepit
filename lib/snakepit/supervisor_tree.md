# Snakepit Supervision Tree

The following Mermaid diagram captures the runtime supervision tree that
`Snakepit.Application` boots. Two sets of children exist:

- **Base services** always start (session store + tool registry).
- **Pooling branch** activates when `:pooling_enabled` is true, which is the
  typical production configuration.

```mermaid
flowchart TD
    A["Snakepit.Supervisor\n(strategy: one_for_one)"]
    A --> B["Snakepit.Bridge.SessionStore\n(GenServer)"]
    A --> C["Snakepit.Bridge.ToolRegistry\n(GenServer)"]

    subgraph "Pooling Enabled (:pooling_enabled == true)"
        direction TB
        A --> D["GRPC.Server.Supervisor\nSnakepit.GRPC.Endpoint"]
        D --> D1["Cowboy/Ranch Acceptors"]

        A --> E["Task.Supervisor\n(Snakepit.TaskSupervisor)"]
        A --> F["Snakepit.Pool.Registry\n(Registry)"]
        A --> G["Snakepit.Pool.Worker.StarterRegistry\n(Registry)"]
        A --> H["Snakepit.Pool.ProcessRegistry\n(GenServer + ETS)"]
        A --> I["Snakepit.Pool.WorkerSupervisor\n(DynamicSupervisor)"]
        A --> J["Snakepit.Worker.LifecycleManager\n(GenServer)"]
        A --> K["Snakepit.Pool\n(GenServer)\nrequest routing"]
        A --> L["Snakepit.Pool.ApplicationCleanup\n(GenServer)\nfirst to stop"]
    end

    subgraph "Pooling Disabled (:pooling_enabled == false)"
        direction TB
        A --> M["(no additional children)\nuseful for tests"]
    end
```

**Notes**

- `GRPC.Server.Supervisor` encapsulates `Snakepit.GRPC.Endpoint` which exposes
  the Elixir bridge services.
- `Snakepit.Pool.WorkerSupervisor` dynamically supervises worker GenServers
  (`Snakepit.GRPCWorker` et al.) under a `:one_for_one` strategy.
- `Snakepit.Pool.ProcessRegistry` tracks external OS PIDs and run IDs to ensure
  cleanup routines know which processes belong to the current BEAM instance.
- `Snakepit.Pool.ApplicationCleanup` is intentionally listed last so it
  terminates first and can reap external processes before other supervisors
  shut down.
