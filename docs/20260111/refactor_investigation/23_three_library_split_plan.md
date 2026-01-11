# Three-Library Split Implementation Plan

## Overview

This document provides a detailed implementation plan for splitting the Snakepit monolith into three separate, reusable libraries aligned with the Nucleus Architecture vision.

---

## 1. Target Library Structure

```
snakepit-ecosystem/
├── nucleus-pool/           # Generic worker pool management
│   ├── lib/
│   │   └── nucleus/
│   │       ├── pool.ex
│   │       ├── pool/
│   │       │   ├── state.ex
│   │       │   ├── dispatcher.ex
│   │       │   ├── event_handler.ex
│   │       │   ├── queue.ex
│   │       │   └── scheduler.ex
│   │       └── ports/
│   │           └── runtime.ex      # Behaviour definition
│   └── mix.exs
│
├── snakepit-runtime/       # Python IPC via gRPC
│   ├── lib/
│   │   └── snakepit/
│   │       └── runtime/
│   │           ├── worker.ex       # GRPCWorker
│   │           ├── bootstrap.ex
│   │           ├── process_manager.ex
│   │           ├── adapter.ex
│   │           ├── adapters/
│   │           │   └── grpc_python.ex
│   │           └── grpc/
│   │               ├── client.ex
│   │               ├── bridge_server.ex
│   │               └── listener.ex
│   └── mix.exs
│
└── snakepit/               # Integration library
    ├── lib/
    │   └── snakepit/
    │       ├── application.ex
    │       ├── config.ex
    │       └── api.ex          # Public facade
    └── mix.exs
```

---

## 2. Library Specifications

### 2.1 nucleus-pool

**Purpose**: Runtime-agnostic worker pool management

**Dependencies**:
```elixir
# mix.exs
defp deps do
  [
    {:telemetry, "~> 1.0"}
  ]
end
```

**Public API**:
```elixir
defmodule Nucleus.Pool do
  @doc "Execute command on any available worker"
  def execute(command, args, opts \\ [])

  @doc "Execute streaming command with callback"
  def execute_stream(command, args, callback, opts \\ [])

  @doc "Wait for pool to be fully initialized"
  def await_ready(pool \\ __MODULE__, timeout \\ nil)

  @doc "Get pool statistics"
  def get_stats(pool \\ __MODULE__)
end
```

**Behaviour Ports**:
```elixir
defmodule Nucleus.Ports.Runtime do
  @moduledoc """
  Behaviour that runtime implementations must satisfy.
  This is how nucleus-pool communicates with external workers.
  """

  @doc "Start a worker process"
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc "Execute a command on the worker"
  @callback execute(worker :: pid() | atom(), command :: String.t(),
    args :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Execute streaming command"
  @callback execute_stream(worker :: pid() | atom(), command :: String.t(),
    args :: map(), callback :: function(), opts :: keyword()) ::
    :ok | {:error, term()}

  @doc "Check worker health"
  @callback health_check(worker :: pid() | atom()) ::
    {:ok, map()} | {:error, term()}

  @doc "Get worker information"
  @callback get_info(worker :: pid() | atom()) :: {:ok, map()}

  @doc "Graceful shutdown"
  @callback shutdown(worker :: pid() | atom(), reason :: term()) :: :ok
end

defmodule Nucleus.Pool.SchedulerStrategy do
  @moduledoc "Pluggable worker selection strategy"

  @doc "Select next worker for a request"
  @callback select_worker(available :: MapSet.t(), context :: map()) ::
    {:ok, worker_id :: term()} | {:error, :no_workers}

  @doc "Handle session affinity routing"
  @callback route_session(session_id :: String.t(), workers :: list()) ::
    {:ok, worker_id :: term()} | :no_preference
end
```

### 2.2 snakepit-runtime

**Purpose**: Python process management via gRPC

**Dependencies**:
```elixir
# mix.exs
defp deps do
  [
    {:grpc, "~> 0.9"},
    {:protobuf, "~> 0.12"},
    {:jason, "~> 1.4"},
    {:telemetry, "~> 1.0"},
    # Behaviour definition from nucleus-pool
    {:nucleus_pool, "~> 1.0", optional: true}
  ]
end
```

**Public API**:
```elixir
defmodule Snakepit.Runtime.Worker do
  @moduledoc """
  gRPC-based Python worker.
  Implements Nucleus.Ports.Runtime behaviour when nucleus-pool is available.
  """

  @behaviour Nucleus.Ports.Runtime  # When available

  def start_link(opts)
  def execute(worker, command, args, opts \\ [])
  def execute_stream(worker, command, args, callback, opts \\ [])
  def health_check(worker)
  def get_info(worker)
end

defmodule Snakepit.Runtime.Adapter do
  @moduledoc "Behaviour for runtime adapters"

  @callback executable_path() :: String.t()
  @callback script_path() :: String.t()
  @callback script_args() :: [String.t()]
  @callback command_timeout(command :: String.t(), args :: map()) :: pos_integer()
end
```

### 2.3 snakepit (Integration)

**Purpose**: Glue layer providing backward-compatible API

**Dependencies**:
```elixir
# mix.exs
defp deps do
  [
    {:nucleus_pool, "~> 1.0"},
    {:snakepit_runtime, "~> 1.0"}
  ]
end
```

**Public API** (backward compatible):
```elixir
defmodule Snakepit do
  @moduledoc "Main entry point - delegates to Nucleus.Pool"

  defdelegate execute(command, args, opts \\ []), to: Nucleus.Pool
  defdelegate execute_stream(command, args, callback, opts \\ []), to: Nucleus.Pool
  defdelegate await_ready(opts \\ []), to: Nucleus.Pool
  defdelegate get_stats(), to: Nucleus.Pool
end
```

---

## 3. Module Migration Map

### 3.1 To nucleus-pool

| Current Path | New Path | Changes Needed |
|--------------|----------|----------------|
| `lib/snakepit/pool/pool.ex` | `lib/nucleus/pool.ex` | Remove GRPCWorker refs |
| `lib/snakepit/pool/state.ex` | `lib/nucleus/pool/state.ex` | Remove GRPCWorker default |
| `lib/snakepit/pool/dispatcher.ex` | `lib/nucleus/pool/dispatcher.ex` | Abstract worker calls |
| `lib/snakepit/pool/event_handler.ex` | `lib/nucleus/pool/event_handler.ex` | Use RuntimePort |
| `lib/snakepit/pool/initializer.ex` | `lib/nucleus/pool/initializer.ex` | Remove GRPC.Listener call |
| `lib/snakepit/pool/queue.ex` | `lib/nucleus/pool/queue.ex` | No changes |
| `lib/snakepit/pool/scheduler.ex` | `lib/nucleus/pool/scheduler.ex` | Extract to behaviour |
| `lib/snakepit/pool/registry.ex` | `lib/nucleus/pool/registry.ex` | No changes |
| `lib/snakepit/pool/worker_supervisor.ex` | `lib/nucleus/pool/worker_supervisor.ex` | Abstract worker start |
| `lib/snakepit/crash_barrier.ex` | `lib/nucleus/pool/crash_barrier.ex` | No changes |

### 3.2 To snakepit-runtime

| Current Path | New Path | Changes Needed |
|--------------|----------|----------------|
| `lib/snakepit/grpc_worker.ex` | `lib/snakepit/runtime/worker.ex` | Implement RuntimePort |
| `lib/snakepit/grpc_worker/bootstrap.ex` | `lib/snakepit/runtime/bootstrap.ex` | Minor path updates |
| `lib/snakepit/grpc_worker/instrumentation.ex` | `lib/snakepit/runtime/instrumentation.ex` | No changes |
| `lib/snakepit/worker/process_manager.ex` | `lib/snakepit/runtime/process_manager.ex` | No changes |
| `lib/snakepit/worker/lifecycle_manager.ex` | `lib/snakepit/runtime/lifecycle_manager.ex` | No changes |
| `lib/snakepit/adapter.ex` | `lib/snakepit/runtime/adapter.ex` | No changes |
| `lib/snakepit/adapters/grpc_python.ex` | `lib/snakepit/runtime/adapters/grpc_python.ex` | No changes |
| `lib/snakepit/grpc/*.ex` | `lib/snakepit/runtime/grpc/*.ex` | Abstract Pool.Registry |
| `lib/snakepit/bridge/*.ex` | `lib/snakepit/runtime/bridge/*.ex` | No changes |
| `lib/snakepit/python_*.ex` | `lib/snakepit/runtime/python_*.ex` | No changes |

### 3.3 To snakepit (Integration)

| Current Path | New Path | Changes Needed |
|--------------|----------|----------------|
| `lib/snakepit/application.ex` | `lib/snakepit/application.ex` | Wire nucleus-pool + runtime |
| `lib/snakepit/config.ex` | `lib/snakepit/config.ex` | Merge configs |
| `lib/snakepit.ex` | `lib/snakepit.ex` | Delegate to Nucleus.Pool |
| `lib/snakepit/defaults.ex` | Split between packages | Context-specific defaults |

---

## 4. Implementation Phases

### Phase 1: Define Behaviours (Week 1)

**Goal**: Create behaviour definitions without moving code

```elixir
# In current snakepit, add:
# lib/snakepit/ports/runtime.ex
defmodule Snakepit.Ports.Runtime do
  @callback start_link(config :: map()) :: GenServer.on_start()
  @callback execute(worker, command, args, opts) :: {:ok, term()} | {:error, term()}
  @callback execute_stream(worker, command, args, callback, opts) :: :ok | {:error, term()}
  @callback health_check(worker) :: {:ok, map()} | {:error, term()}
end

# Update GRPCWorker to implement:
defmodule Snakepit.GRPCWorker do
  @behaviour Snakepit.Ports.Runtime
  # ... existing code ...
end
```

**Tasks**:
1. Create `Snakepit.Ports.Runtime` behaviour
2. Create `Snakepit.Pool.SchedulerStrategy` behaviour
3. Update `GRPCWorker` to declare `@behaviour`
4. Update `Pool.Scheduler` to declare `@behaviour`
5. Add tests for behaviour compliance

### Phase 2: Inject Dependencies (Week 2)

**Goal**: Replace hardcoded references with configuration

```elixir
# Before (pool/state.ex:40):
worker_module = opts[:worker_module] || Snakepit.GRPCWorker

# After:
worker_module = opts[:worker_module] ||
  Application.get_env(:snakepit, :default_worker_module) ||
  raise "No worker module configured"
```

**Tasks**:
1. Add `:default_worker_module` config option
2. Add `:scheduler_strategy` config option
3. Update `Pool.State` to use config
4. Update `Pool` fallback to use config
5. Update `Pool.Initializer` to use callback instead of direct GRPC.Listener call
6. Add init callback behaviour for startup coordination

### Phase 3: Create Package Structure (Week 3)

**Goal**: Create separate mix projects

```bash
# Create nucleus-pool package
mkdir -p packages/nucleus_pool/lib/nucleus
cp -r lib/snakepit/pool packages/nucleus_pool/lib/nucleus/
# Update module names

# Create snakepit-runtime package
mkdir -p packages/snakepit_runtime/lib/snakepit/runtime
cp lib/snakepit/grpc_worker.ex packages/snakepit_runtime/lib/snakepit/runtime/worker.ex
# ... copy other files
```

**Tasks**:
1. Create `packages/nucleus_pool/` directory structure
2. Create `packages/snakepit_runtime/` directory structure
3. Create mix.exs for each package
4. Copy and rename modules
5. Update all module references

### Phase 4: Resolve Cross-Package Dependencies (Week 4)

**Goal**: Clean separation between packages

**Critical Changes**:

```elixir
# In nucleus-pool: Pool.Initializer
# Before:
defp ensure_grpc_listener_ready! do
  case Snakepit.GRPC.Listener.await_ready() do
    {:ok, _} -> :ok
    {:error, :timeout} -> exit({:grpc_listener_unavailable, :timeout})
  end
end

# After:
defp ensure_runtime_ready!(config) do
  callback = config[:pre_init_callback] || fn -> :ok end
  case callback.() do
    :ok -> :ok
    {:error, reason} -> exit({:runtime_unavailable, reason})
  end
end
```

```elixir
# In snakepit-runtime: BridgeServer
# Before:
case PoolRegistry.get_worker_pid(worker_id) do

# After:
registry = Application.get_env(:snakepit_runtime, :worker_registry)
case registry.get_worker_pid(worker_id) do
```

**Tasks**:
1. Replace direct GRPC.Listener call with callback
2. Abstract Pool.Registry access in BridgeServer
3. Remove all cross-package direct references
4. Add integration tests

### Phase 5: Integration and Testing (Week 5)

**Goal**: Working split with full test coverage

**Tasks**:
1. Create snakepit integration package
2. Wire all three packages together
3. Migrate all tests
4. Ensure backward compatibility
5. Update all examples
6. Performance benchmarking

---

## 5. Configuration Migration

### Current Configuration

```elixir
# config/config.exs
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pool_config: %{
    size: 4,
    startup_timeout: 30_000
  }
```

### New Configuration

```elixir
# config/config.exs

# Generic pool configuration
config :nucleus_pool,
  default_pool_size: 4,
  startup_timeout: 30_000,
  queue_timeout: 30_000,
  scheduler_strategy: Nucleus.Pool.DefaultScheduler

# Python runtime configuration
config :snakepit_runtime,
  adapter_module: Snakepit.Runtime.Adapters.GRPCPython,
  grpc_listener: %{mode: :internal},
  graceful_shutdown_timeout_ms: 6_000

# Integration configuration
config :snakepit,
  runtime_module: Snakepit.Runtime.Worker,
  pre_init_callback: &Snakepit.Runtime.GRPC.Listener.await_ready/0
```

---

## 6. Backward Compatibility Strategy

### 6.1 Facade Module

```elixir
# lib/snakepit.ex - Maintains old API
defmodule Snakepit do
  @moduledoc """
  Main entry point for Snakepit.
  Provides backward-compatible API delegating to nucleus-pool.
  """

  defdelegate execute(command, args, opts \\ []), to: Nucleus.Pool
  defdelegate execute_stream(command, args, callback, opts \\ []), to: Nucleus.Pool
  defdelegate await_ready(opts \\ []), to: Nucleus.Pool

  # Deprecated functions with warnings
  @deprecated "Use Nucleus.Pool.get_stats/1 instead"
  def get_stats, do: Nucleus.Pool.get_stats()
end
```

### 6.2 Configuration Shim

```elixir
# lib/snakepit/config_shim.ex
defmodule Snakepit.ConfigShim do
  @moduledoc "Translates old config format to new"

  def translate_config do
    old_config = Application.get_all_env(:snakepit)

    # Map old keys to new locations
    if pool_config = old_config[:pool_config] do
      Application.put_env(:nucleus_pool, :default_pool_size, pool_config[:size])
      # ... more translations
    end
  end
end
```

### 6.3 Deprecation Timeline

| Version | Status | Notes |
|---------|--------|-------|
| 1.0.0 | Current | Monolithic |
| 2.0.0-alpha | Split packages | Old API works with warnings |
| 2.0.0 | Stable split | Old API deprecated |
| 3.0.0 | Clean | Old API removed |

---

## 7. Testing Strategy

### 7.1 Unit Tests per Package

```elixir
# nucleus_pool/test/nucleus/pool_test.exs
defmodule Nucleus.PoolTest do
  use ExUnit.Case

  # Mock runtime for isolated testing
  defmodule MockRuntime do
    @behaviour Nucleus.Ports.Runtime
    def start_link(_), do: {:ok, spawn(fn -> :ok end)}
    def execute(_, _, _, _), do: {:ok, %{result: "mock"}}
    # ...
  end

  setup do
    Application.put_env(:nucleus_pool, :runtime_module, MockRuntime)
    :ok
  end

  test "execute routes to available worker" do
    # Test without real Python
  end
end
```

### 7.2 Integration Tests

```elixir
# snakepit/test/integration/full_stack_test.exs
defmodule Snakepit.FullStackTest do
  use ExUnit.Case

  @tag :integration
  test "execute with real Python worker" do
    {:ok, result} = Snakepit.execute("echo", %{message: "hello"})
    assert result["message"] == "hello"
  end
end
```

---

## 8. Risk Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Breaking API changes | Medium | High | Facade layer + deprecation warnings |
| Performance regression | Low | Medium | Benchmark before/after each phase |
| Test coverage gaps | Medium | Medium | Add contract tests at boundaries |
| Dependency version conflicts | Low | High | Pin shared dependencies |
| Documentation drift | High | Low | Generate docs from source |

---

## 9. Success Criteria

### Technical

- [ ] Zero breaking changes to public API in initial release
- [ ] All existing tests pass with new structure
- [ ] Performance within 5% of monolith
- [ ] Each package publishable to Hex independently

### Architectural

- [ ] nucleus-pool has no Python/gRPC references
- [ ] snakepit-runtime can work standalone
- [ ] Clear behaviour boundaries documented
- [ ] No circular dependencies between packages

### Documentation

- [ ] Updated README for each package
- [ ] Migration guide for existing users
- [ ] Architecture decision records (ADRs)
- [ ] Updated examples

---

*Generated: 2026-01-11*
*Aligned with Nucleus Architecture specification v2.0*
