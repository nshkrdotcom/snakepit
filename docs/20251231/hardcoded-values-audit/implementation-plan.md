# Snakepit Configuration Streamlining - Implementation Plan

## Phase 1: Critical Timeout Fixes (Immediate)

### 1.1 Fix Default Command Timeout

**File:** `lib/snakepit/pool/pool.ex`

```elixir
# Line 2243 - CHANGE FROM:
nil -> 30_000

# TO:
nil -> Application.get_env(:snakepit, :default_command_timeout, :infinity)
```

### 1.2 Fix Worker Execute Timeout

**File:** `lib/snakepit/grpc_worker.ex`

```elixir
# Line 122 - CHANGE FROM:
def execute(worker, command, args, timeout \\ 30_000)

# TO:
def execute(worker, command, args, timeout \\ nil)
# Then resolve nil to config default inside the function
```

### 1.3 Fix gRPC Command Timeout

**File:** `lib/snakepit/adapters/grpc_python.ex`

```elixir
# Line 250 - CHANGE FROM:
def command_timeout(_command, _args), do: 30_000

# TO:
def command_timeout(_command, _args) do
  Application.get_env(:snakepit, :default_command_timeout, :infinity)
end
```

## Phase 2: Create Unified Config Module

### 2.1 New File: `lib/snakepit/defaults.ex`

```elixir
defmodule Snakepit.Defaults do
  @moduledoc """
  Centralized defaults for all configurable values.
  """

  # Timeouts (milliseconds, or :infinity)
  def default_command_timeout, do: get(:default_command_timeout, :infinity)
  def pool_request_timeout, do: get(:pool_request_timeout, 300_000)
  def pool_streaming_timeout, do: get(:pool_streaming_timeout, 600_000)
  def pool_startup_timeout, do: get(:pool_startup_timeout, 30_000)
  def pool_queue_timeout, do: get(:pool_queue_timeout, 30_000)
  def checkout_timeout, do: get(:checkout_timeout, 10_000)
  def heartbeat_timeout, do: get(:heartbeat_timeout, 30_000)
  def graceful_shutdown_timeout, do: get(:graceful_shutdown_timeout, 10_000)

  # Intervals (milliseconds)
  def heartbeat_interval, do: get(:heartbeat_interval, 5_000)
  def health_check_interval, do: get(:health_check_interval, 60_000)
  def session_cleanup_interval, do: get(:session_cleanup_interval, 120_000)
  def worker_lifecycle_interval, do: get(:worker_lifecycle_interval, 120_000)
  def process_registry_cleanup_interval, do: get(:process_registry_cleanup_interval, 60_000)

  # Pool settings
  def max_queue_size, do: get(:max_queue_size, 10_000)
  def max_workers_cap, do: get(:max_workers_cap, 500)
  def max_cancelled_entries, do: get(:max_cancelled_entries, 2048)

  # Retry settings
  def max_retry_attempts, do: get(:max_retry_attempts, 5)
  def max_backoff_ms, do: get(:max_backoff_ms, 60_000)
  def default_backoff_sequence, do: get(:backoff_sequence, [100, 200, 400, 800, 1600, 3200])

  # gRPC settings
  def grpc_num_acceptors, do: get(:grpc_num_acceptors, 50)
  def grpc_max_connections, do: get(:grpc_max_connections, 5000)
  def grpc_socket_backlog, do: get(:grpc_socket_backlog, 1024)

  defp get(key, default) do
    Application.get_env(:snakepit, key, default)
  end
end
```

## Phase 3: Update All Hardcoded References

### Files to Update

1. **pool/pool.ex** - 15 hardcoded values
2. **grpc_worker.ex** - 5 hardcoded values
3. **adapters/grpc_python.ex** - 4 hardcoded values
4. **executor.ex** - 2 hardcoded values
5. **health_monitor.ex** - 3 hardcoded values
6. **retry_policy.ex** - 4 hardcoded values
7. **circuit_breaker.ex** - 3 hardcoded values
8. **crash_barrier.ex** - 3 hardcoded values
9. **application.ex** - 5 hardcoded values
10. **worker/lifecycle_manager.ex** - 3 hardcoded values
11. **bridge/session_store.ex** - 4 hardcoded values
12. **pool/process_registry.ex** - 2 hardcoded values

### Pattern for Each Change

```elixir
# BEFORE
timeout = opts[:timeout] || 30_000

# AFTER
timeout = opts[:timeout] || Snakepit.Defaults.default_command_timeout()
```

## Phase 4: Documentation

### 4.1 Update README

Add configuration section documenting all options.

### 4.2 Add Config Examples

```elixir
# config/runtime.exs example for production
config :snakepit,
  default_command_timeout: :infinity,
  pool_request_timeout: 300_000,
  max_queue_size: 50_000
```

## Testing Plan

1. Ensure all existing tests pass with new defaults
2. Add tests for config overrides
3. Add tests for `:infinity` timeout handling
4. Load test with new defaults

## Migration Notes

- Existing deployments will get new (safer) defaults
- No breaking changes to public API
- Config keys are additive
