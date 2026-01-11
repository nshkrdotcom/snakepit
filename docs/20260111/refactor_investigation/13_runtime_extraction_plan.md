# Runtime Extraction Plan: snakepit-runtime

## Overview

This document details the extraction of Python-specific IPC functionality from the Snakepit monolith into a standalone `snakepit-runtime` library. This library will implement the `Nucleus.Ports.Runtime` behaviour, allowing it to integrate with the generic `nucleus-pool` or operate independently.

---

## 1. Extraction Scope

### 1.1 Modules to Extract

| Current Location | New Location | Purpose |
|------------------|--------------|---------|
| `lib/snakepit/grpc_worker.ex` | `lib/snakepit/runtime/worker.ex` | Main worker GenServer |
| `lib/snakepit/grpc_worker/bootstrap.ex` | `lib/snakepit/runtime/worker/bootstrap.ex` | Worker initialization |
| `lib/snakepit/grpc_worker/instrumentation.ex` | `lib/snakepit/runtime/worker/instrumentation.ex` | Telemetry integration |
| `lib/snakepit/worker/process_manager.ex` | `lib/snakepit/runtime/process_manager.ex` | Python process lifecycle |
| `lib/snakepit/worker/lifecycle_manager.ex` | `lib/snakepit/runtime/lifecycle_manager.ex` | Worker lifecycle tracking |
| `lib/snakepit/worker/configuration.ex` | `lib/snakepit/runtime/configuration.ex` | Worker config helpers |
| `lib/snakepit/adapter.ex` | `lib/snakepit/runtime/adapter.ex` | Adapter behaviour |
| `lib/snakepit/adapters/grpc_python.ex` | `lib/snakepit/runtime/adapters/grpc_python.ex` | Python gRPC adapter |
| `lib/snakepit/grpc/*.ex` | `lib/snakepit/runtime/grpc/*.ex` | gRPC infrastructure |
| `lib/snakepit/bridge/*.ex` | `lib/snakepit/runtime/bridge/*.ex` | Session & tool management |
| `lib/snakepit/python_*.ex` | `lib/snakepit/runtime/python/*.ex` | Python runtime helpers |
| `lib/snakepit/hardware/*.ex` | `lib/snakepit/runtime/hardware/*.ex` | Hardware detection |
| `lib/snakepit/heartbeat_monitor.ex` | `lib/snakepit/runtime/heartbeat_monitor.ex` | Heartbeat monitoring |

### 1.2 Files to Keep in snakepit

| File | Reason |
|------|--------|
| `lib/snakepit.ex` | Public API facade |
| `lib/snakepit/application.ex` | Integration layer |
| `lib/snakepit/config.ex` | Unified configuration |

---

## 2. New Package Structure

```
snakepit_runtime/
├── lib/
│   └── snakepit/
│       └── runtime/
│           ├── worker.ex                    # Main GenServer
│           ├── worker/
│           │   ├── bootstrap.ex
│           │   └── instrumentation.ex
│           ├── process_manager.ex
│           ├── lifecycle_manager.ex
│           ├── configuration.ex
│           ├── adapter.ex                   # Behaviour
│           ├── adapters/
│           │   └── grpc_python.ex
│           ├── grpc/
│           │   ├── listener.ex
│           │   ├── endpoint.ex
│           │   ├── client.ex
│           │   ├── client_impl.ex
│           │   └── bridge_server.ex
│           ├── bridge/
│           │   ├── session.ex
│           │   ├── session_store.ex
│           │   └── tool_registry.ex
│           ├── python/
│           │   ├── runtime.ex
│           │   ├── packages.ex
│           │   └── version.ex
│           ├── hardware/
│           │   ├── detector.ex
│           │   ├── cuda_detector.ex
│           │   ├── cpu_detector.ex
│           │   └── ...
│           └── heartbeat_monitor.ex
├── priv/
│   └── python/
│       ├── grpc_server.py
│       ├── grpc_server_threaded.py
│       └── snakepit_bridge/
│           └── ...
├── mix.exs
└── README.md
```

---

## 3. Behaviour Implementation

### 3.1 RuntimePort Behaviour (from nucleus-pool)

```elixir
# When nucleus-pool is available, implement its behaviour
defmodule Snakepit.Runtime.Worker do
  @moduledoc """
  gRPC-based Python worker implementing Nucleus.Ports.Runtime.
  """

  use GenServer

  # Conditional behaviour implementation
  if Code.ensure_loaded?(Nucleus.Ports.Runtime) do
    @behaviour Nucleus.Ports.Runtime
  end

  # Existing worker implementation...
end
```

### 3.2 Standalone Operation

```elixir
# For use without nucleus-pool
defmodule Snakepit.Runtime do
  @moduledoc """
  Standalone runtime API when not using nucleus-pool.
  """

  @doc "Start a single worker"
  defdelegate start_worker(opts), to: Snakepit.Runtime.Worker, as: :start_link

  @doc "Execute on a specific worker"
  defdelegate execute(worker, command, args, opts \\ []), to: Snakepit.Runtime.Worker

  @doc "Execute streaming on a specific worker"
  defdelegate execute_stream(worker, command, args, callback, opts \\ []),
    to: Snakepit.Runtime.Worker
end
```

---

## 4. Dependencies

### 4.1 External Dependencies

```elixir
# mix.exs
defp deps do
  [
    # gRPC communication
    {:grpc, "~> 0.9"},
    {:protobuf, "~> 0.12"},

    # JSON encoding
    {:jason, "~> 1.4"},

    # Telemetry
    {:telemetry, "~> 1.0"},

    # Optional: nucleus-pool integration
    {:nucleus_pool, "~> 1.0", optional: true}
  ]
end
```

### 4.2 Removed Dependencies

The following are NOT needed in snakepit-runtime:
- Pool management (moved to nucleus-pool)
- Queue management (moved to nucleus-pool)
- Scheduling logic (moved to nucleus-pool)

---

## 5. Configuration Extraction

### 5.1 Runtime-Specific Configuration

```elixir
# config/config.exs for snakepit-runtime
config :snakepit_runtime,
  # Python process configuration
  python_executable: "python3",
  graceful_shutdown_timeout_ms: 6_000,

  # gRPC listener configuration
  grpc_listener: %{
    mode: :internal,  # :internal | :external
    host: "localhost",
    port: 0           # 0 = OS-assigned
  },

  # Heartbeat configuration
  heartbeat: %{
    enabled: false,
    ping_interval_ms: 10_000,
    timeout_ms: 5_000,
    max_missed_heartbeats: 3
  },

  # Adapter configuration
  adapter_module: Snakepit.Runtime.Adapters.GRPCPython,

  # Worker registry (injected by pool)
  worker_registry: nil
```

### 5.2 Configuration Migration

| Old Key (snakepit) | New Key (snakepit_runtime) |
|--------------------|----------------------------|
| `:adapter_module` | `:adapter_module` |
| `:grpc_listener` | `:grpc_listener` |
| `:graceful_shutdown_timeout_ms` | `:graceful_shutdown_timeout_ms` |
| `:heartbeat` | `:heartbeat` |
| `:pool_config.adapter_args` | `:adapter_args` |

---

## 6. API Changes

### 6.1 Worker Public API

```elixir
defmodule Snakepit.Runtime.Worker do
  @doc "Start a worker with configuration"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts)

  @doc "Execute command on worker"
  @spec execute(worker(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(worker, command, args, opts \\ [])

  @doc "Execute streaming command"
  @spec execute_stream(worker(), String.t(), map(), function(), keyword()) ::
    :ok | {:error, term()}
  def execute_stream(worker, command, args, callback, opts \\ [])

  @doc "Get worker health"
  @spec get_health(worker()) :: {:ok, map()} | {:error, term()}
  def get_health(worker)

  @doc "Get worker info"
  @spec get_info(worker()) :: {:ok, map()}
  def get_info(worker)

  @doc "Get gRPC channel for direct use"
  @spec get_channel(worker()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def get_channel(worker)

  @doc "Get session ID"
  @spec get_session_id(worker()) :: {:ok, String.t()}
  def get_session_id(worker)
end
```

### 6.2 Adapter Public API

```elixir
defmodule Snakepit.Runtime.Adapter do
  @moduledoc "Behaviour for runtime adapters"

  @callback executable_path() :: String.t()
  @callback script_path() :: String.t()
  @callback script_args() :: [String.t()]
  @callback command_timeout(String.t(), map()) :: pos_integer()

  @optional_callbacks [command_timeout: 2]
end

defmodule Snakepit.Runtime.Adapters.GRPCPython do
  @behaviour Snakepit.Runtime.Adapter

  @doc "Initialize gRPC connection with retry"
  @spec init_grpc_connection(port :: integer()) ::
    {:ok, map()} | {:error, term()}
  def init_grpc_connection(port)

  @doc "Execute via gRPC"
  @spec grpc_execute(connection, session_id, command, args, timeout, opts) ::
    {:ok, term()} | {:error, term()}
  def grpc_execute(connection, session_id, command, args, timeout \\ nil, opts \\ [])

  @doc "Execute streaming via gRPC"
  @spec grpc_execute_stream(connection, session_id, command, args, callback, timeout, opts) ::
    :ok | {:error, term()}
  def grpc_execute_stream(connection, session_id, command, args, callback, timeout \\ nil, opts \\ [])
end
```

---

## 7. Breaking Changes

### 7.1 Module Renames

| Old Module | New Module |
|------------|------------|
| `Snakepit.GRPCWorker` | `Snakepit.Runtime.Worker` |
| `Snakepit.Adapter` | `Snakepit.Runtime.Adapter` |
| `Snakepit.Adapters.GRPCPython` | `Snakepit.Runtime.Adapters.GRPCPython` |
| `Snakepit.GRPC.Listener` | `Snakepit.Runtime.GRPC.Listener` |
| `Snakepit.GRPC.BridgeServer` | `Snakepit.Runtime.GRPC.BridgeServer` |
| `Snakepit.Bridge.SessionStore` | `Snakepit.Runtime.Bridge.SessionStore` |
| `Snakepit.Bridge.ToolRegistry` | `Snakepit.Runtime.Bridge.ToolRegistry` |

### 7.2 Backward Compatibility Shim

```elixir
# In snakepit (integration package)
# lib/snakepit/compat.ex
defmodule Snakepit.GRPCWorker do
  @moduledoc false
  # Deprecated - use Snakepit.Runtime.Worker
  defdelegate start_link(opts), to: Snakepit.Runtime.Worker
  defdelegate execute(worker, cmd, args, opts), to: Snakepit.Runtime.Worker
  # ...
end
```

---

## 8. Integration Points

### 8.1 With nucleus-pool

```elixir
# In snakepit application.ex
def start(_type, _args) do
  children = [
    # Start runtime services
    Snakepit.Runtime.Bridge.SessionStore,
    {Snakepit.Runtime.GRPC.Listener, grpc_config()},

    # Start pool with runtime configuration
    {Nucleus.Pool, [
      runtime_module: Snakepit.Runtime.Worker,
      pre_init_callback: &Snakepit.Runtime.GRPC.Listener.await_ready/0,
      # ... other pool config
    ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### 8.2 Standalone (without pool)

```elixir
# Direct worker usage
{:ok, worker} = Snakepit.Runtime.Worker.start_link(
  adapter: Snakepit.Runtime.Adapters.GRPCPython,
  id: "worker-1"
)

{:ok, result} = Snakepit.Runtime.Worker.execute(worker, "echo", %{message: "hello"})
```

---

## 9. Testing Strategy

### 9.1 Unit Tests

```elixir
# test/snakepit/runtime/worker_test.exs
defmodule Snakepit.Runtime.WorkerTest do
  use ExUnit.Case

  # Mock Python process for isolated testing
  setup do
    # Start mock gRPC server
    {:ok, mock_server} = MockGRPCServer.start_link()
    %{mock: mock_server}
  end

  test "execute sends request via gRPC" do
    # Test without real Python
  end
end
```

### 9.2 Integration Tests

```elixir
# test/integration/python_worker_test.exs
defmodule Snakepit.Runtime.PythonWorkerTest do
  use ExUnit.Case

  @moduletag :integration

  setup do
    {:ok, worker} = Snakepit.Runtime.Worker.start_link(
      adapter: Snakepit.Runtime.Adapters.GRPCPython
    )
    on_exit(fn -> GenServer.stop(worker) end)
    %{worker: worker}
  end

  test "echo command works", %{worker: worker} do
    assert {:ok, %{"message" => "hello"}} =
      Snakepit.Runtime.Worker.execute(worker, "echo", %{"message" => "hello"})
  end
end
```

---

## 10. Migration Checklist

### Phase 1: Preparation

- [ ] Create `snakepit_runtime` mix project
- [ ] Copy Python files to new priv directory
- [ ] Set up protobuf compilation

### Phase 2: Module Migration

- [ ] Move `grpc_worker.ex` → `runtime/worker.ex`
- [ ] Move `grpc_worker/*.ex` → `runtime/worker/*.ex`
- [ ] Move `worker/*.ex` → `runtime/*.ex`
- [ ] Move `adapter.ex` → `runtime/adapter.ex`
- [ ] Move `adapters/*.ex` → `runtime/adapters/*.ex`
- [ ] Move `grpc/*.ex` → `runtime/grpc/*.ex`
- [ ] Move `bridge/*.ex` → `runtime/bridge/*.ex`
- [ ] Move `python_*.ex` → `runtime/python/*.ex`
- [ ] Move `hardware/*.ex` → `runtime/hardware/*.ex`

### Phase 3: Namespace Updates

- [ ] Update all module names
- [ ] Update all alias/import statements
- [ ] Update internal references
- [ ] Update tests

### Phase 4: Configuration

- [ ] Extract runtime-specific config
- [ ] Create defaults module
- [ ] Update config documentation

### Phase 5: Integration

- [ ] Add nucleus-pool optional dependency
- [ ] Implement RuntimePort behaviour conditionally
- [ ] Create standalone API
- [ ] Create backward compat shims

### Phase 6: Testing

- [ ] Migrate unit tests
- [ ] Add integration tests
- [ ] Test standalone operation
- [ ] Test with nucleus-pool

---

*Generated: 2026-01-11*
*Part of Snakepit three-library split initiative*
