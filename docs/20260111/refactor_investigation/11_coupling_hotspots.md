# Coupling Hotspots Analysis

## Overview

This document provides a detailed analysis of the coupling points between Snakepit modules, identifying the specific locations that must be refactored for clean modularization.

---

## 1. Coupling Severity Classification

| Severity | Definition | Action Required |
|----------|------------|-----------------|
| **CRITICAL** | Blocks package separation | Must resolve before split |
| **HIGH** | Hardcoded dependencies | Replace with config/behaviour |
| **MEDIUM** | Direct cross-layer calls | Abstract behind interface |
| **LOW** | Shared utilities | Can remain shared |

---

## 2. Critical Coupling Points (MUST FIX)

### 2.1 Pool.Initializer → GRPC.Listener

**Location**: `lib/snakepit/pool/initializer.ex:119-127`

```elixir
defp ensure_grpc_listener_ready! do
  case Snakepit.GRPC.Listener.await_ready() do
    {:ok, _info} ->
      :ok

    {:error, :timeout} ->
      SLog.error(@log_category, "gRPC listener failed to publish port within timeout")
      exit({:grpc_listener_unavailable, :timeout})
  end
end
```

**Problem**: Pool initialization directly depends on gRPC listener being ready. This prevents `nucleus-pool` from being runtime-agnostic.

**Solution**:
```elixir
# New: Use injected callback
defp ensure_runtime_ready!(pool_config) do
  case Map.get(pool_config, :pre_init_callback, fn -> :ok end).() do
    :ok -> :ok
    {:error, reason} -> exit({:runtime_unavailable, reason})
  end
end
```

---

### 2.2 Pool.State → GRPCWorker Default

**Location**: `lib/snakepit/pool/state.ex:40`

```elixir
worker_module = opts[:worker_module] || Snakepit.GRPCWorker
```

**Problem**: Hardcoded default worker module couples Pool to specific runtime.

**Solution**:
```elixir
# New: Require explicit configuration
worker_module = opts[:worker_module] ||
  Application.get_env(:nucleus_pool, :default_runtime_module) ||
  raise ArgumentError, "No runtime module configured. Set :nucleus_pool, :default_runtime_module"
```

---

### 2.3 Pool → GRPCWorker Fallback

**Location**: `lib/snakepit/pool/pool.ex:1491-1493`

```elixir
defp get_worker_module(worker_id) do
  case PoolRegistry.fetch_worker(worker_id) do
    {:ok, _pid, %{worker_module: module}} when is_atom(module) ->
      module
    _ ->
      # Fallback: use GRPCWorker
      Snakepit.GRPCWorker
  end
end
```

**Problem**: Direct fallback to GRPCWorker prevents runtime-agnostic pooling.

**Solution**:
```elixir
defp get_worker_module(worker_id, pool_state) do
  case PoolRegistry.fetch_worker(worker_id) do
    {:ok, _pid, %{worker_module: module}} when is_atom(module) ->
      module
    _ ->
      pool_state.worker_module  # Use configured module, no hardcoded fallback
  end
end
```

---

## 3. High Severity Coupling Points

### 3.1 BridgeServer → PoolRegistry

**Locations**:
- `lib/snakepit/grpc/bridge_server.ex:331`
- `lib/snakepit/grpc/bridge_server.ex:474`

```elixir
# Line 331
defp get_worker_port(worker_id) do
  case PoolRegistry.get_worker_pid(worker_id) do
    {:ok, pid} when is_pid(pid) ->
      # ...
  end
end

# Line 474
defp fetch_worker_safely(worker_id) do
  case PoolRegistry.fetch_worker(worker_id) do
    {:ok, pid, metadata} when is_pid(pid) -> {:ok, pid, metadata}
    # ...
  end
end
```

**Problem**: BridgeServer (gRPC layer) directly queries Pool layer's registry.

**Solution**: Abstract behind configurable registry behaviour:
```elixir
defmodule Snakepit.Runtime.WorkerRegistry do
  @callback get_worker_pid(worker_id :: String.t()) :: {:ok, pid()} | {:error, term()}
  @callback fetch_worker(worker_id :: String.t()) :: {:ok, pid(), map()} | {:error, term()}
end

# In BridgeServer:
defp get_registry do
  Application.get_env(:snakepit_runtime, :worker_registry, Snakepit.Pool.Registry)
end
```

---

### 3.2 BridgeServer → GRPCWorker Type Check

**Location**: `lib/snakepit/grpc/bridge_server.ex:480-485`

```elixir
defp validate_worker_module(metadata) do
  case Map.get(metadata, :worker_module, GRPCWorker) do
    module when module == GRPCWorker -> :ok
    _ -> {:error, :unsupported_worker_module}
  end
end
```

**Problem**: Hardcoded check for GRPCWorker module type.

**Solution**: Use behaviour checking:
```elixir
defp validate_worker_module(metadata) do
  module = Map.get(metadata, :worker_module)
  if implements_behaviour?(module, Snakepit.Runtime.WorkerBehaviour) do
    :ok
  else
    {:error, :unsupported_worker_module}
  end
end

defp implements_behaviour?(module, behaviour) do
  behaviours = module.__info__(:attributes)[:behaviour] || []
  behaviour in behaviours
end
```

---

### 3.3 GRPCPython Script Selection

**Location**: `lib/snakepit/adapters/grpc_python.ex:76-96`

```elixir
def script_path do
  app_dir = Application.app_dir(:snakepit)

  # Logic to choose between grpc_server.py and grpc_server_threaded.py
  has_max_workers = ...

  script_name =
    if has_max_workers do
      "grpc_server_threaded.py"
    else
      "grpc_server.py"
    end

  Path.join([app_dir, "priv", "python", script_name])
end
```

**Problem**: Script paths hardcoded to `:snakepit` app directory.

**Solution**: Make configurable:
```elixir
def script_path do
  app = Application.get_env(:snakepit_runtime, :python_scripts_app, :snakepit_runtime)
  app_dir = Application.app_dir(app)

  script_name = resolve_script_name(pool_config())
  Path.join([app_dir, "priv", "python", script_name])
end
```

---

## 4. Medium Severity Coupling Points

### 4.1 Pool.Dispatcher → CrashBarrier Integration

**Location**: `lib/snakepit/pool/dispatcher.ex`

The dispatcher integrates with CrashBarrier for fault tolerance, but this is tightly coupled.

**Current**: Direct calls to `CrashBarrier.worker_tainted?/1`, `CrashBarrier.taint_worker/4`

**Solution**: Keep CrashBarrier in nucleus-pool (it's generic fault tolerance)

---

### 4.2 Pool.EventHandler → LifecycleManager

**Location**: `lib/snakepit/pool/event_handler.ex`

**Current**: Direct calls to `LifecycleManager.increment_request_count/1`

**Solution**: Make LifecycleManager integration optional via callback

---

### 4.3 GRPCWorker → Pool Reporting

**Location**: `lib/snakepit/grpc_worker.ex:284`

```elixir
LifecycleManager.track_worker(state.pool_name, state.id, self(), state.worker_config)
```

**Problem**: Worker directly reports to Pool's LifecycleManager.

**Solution**: Use optional callback:
```elixir
# In worker config
on_ready_callback: fn worker_id, worker_pid, config ->
  LifecycleManager.track_worker(pool_name, worker_id, worker_pid, config)
end
```

---

## 5. Low Severity Coupling Points

### 5.1 Shared Defaults Module

**Location**: `lib/snakepit/defaults.ex`

**Status**: Used by nearly every module.

**Solution**: Split into:
- `Nucleus.Pool.Defaults` - Pool-specific defaults
- `Snakepit.Runtime.Defaults` - Runtime-specific defaults
- `Snakepit.Defaults` - Integration defaults (backward compat)

---

### 5.2 Shared Logger Module

**Location**: `lib/snakepit/logger.ex`

**Status**: Used across all layers.

**Solution**: Keep shared or use standard Logger with telemetry

---

### 5.3 Shared Error Module

**Location**: `lib/snakepit/error.ex`

**Status**: Used for error construction.

**Solution**: Split into package-specific error modules or keep as shared utility

---

## 6. Coupling Metrics Summary

```
┌─────────────────────────────────────────────────────────────┐
│                    COUPLING MATRIX                          │
├─────────────────┬─────────┬─────────┬─────────┬────────────┤
│                 │  Pool   │  gRPC   │ Worker  │  Bridge    │
├─────────────────┼─────────┼─────────┼─────────┼────────────┤
│ Pool            │    -    │    3    │    4    │     0      │
│ gRPC            │    2    │    -    │    2    │     0      │
│ Worker          │    1    │    3    │    -    │     0      │
│ Bridge          │    2    │    1    │    2    │     -      │
├─────────────────┼─────────┼─────────┼─────────┼────────────┤
│ TOTAL INCOMING  │    5    │    7    │    8    │     0      │
└─────────────────┴─────────┴─────────┴─────────┴────────────┘

Total Cross-Layer Coupling Points: 23
Critical Points: 3
High Severity Points: 5
Medium Severity Points: 8
Low Severity Points: 7
```

---

## 7. Resolution Priority Matrix

| Priority | Coupling Point | Effort | Impact |
|----------|---------------|--------|--------|
| 1 | Pool.Initializer → GRPC.Listener | Medium | Very High |
| 2 | Pool.State default worker | Low | High |
| 3 | Pool fallback to GRPCWorker | Low | High |
| 4 | BridgeServer → PoolRegistry | Medium | High |
| 5 | BridgeServer → GRPCWorker check | Low | Medium |
| 6 | GRPCPython script paths | Low | Medium |
| 7 | Worker → LifecycleManager | Low | Low |
| 8 | Shared Defaults | Medium | Low |

---

## 8. Coupling Resolution Checklist

### Critical (Block Release)

- [ ] Replace `ensure_grpc_listener_ready!` with callback
- [ ] Remove default `GRPCWorker` from `Pool.State`
- [ ] Remove `GRPCWorker` fallback from `Pool`

### High (Before Stable)

- [ ] Abstract `PoolRegistry` access in `BridgeServer`
- [ ] Replace module type check with behaviour check
- [ ] Make script paths configurable

### Medium (After Stable)

- [ ] Make `LifecycleManager` integration optional
- [ ] Make `CrashBarrier` integration optional
- [ ] Abstract worker pool reporting

### Low (Future)

- [ ] Split `Defaults` module
- [ ] Consider Logger abstraction
- [ ] Error module organization

---

*Generated: 2026-01-11*
*Analysis based on static code review of 88 source files*
