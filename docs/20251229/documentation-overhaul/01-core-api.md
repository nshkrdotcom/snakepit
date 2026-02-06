# Snakepit Core API Reference

This document provides comprehensive documentation for the Snakepit library's core API, configuration options, and pool management functions.

## Table of Contents

1. [Public API Functions](#public-api-functions)
2. [Configuration Options](#configuration-options)
3. [Pool API](#pool-api)
4. [Working Examples](#working-examples)

---

## Public API Functions

The `Snakepit` module provides the primary interface for executing commands on pooled external workers.

### Type Definitions

```elixir
@type command :: String.t()
@type args :: map()
@type result :: term()
@type session_id :: String.t()
@type callback_fn :: (term() -> any())
@type pool_name :: atom() | pid()
```

### execute/3

Executes a command on any available worker in the pool.

```elixir
@spec execute(command(), args(), keyword()) :: {:ok, result()} | {:error, Snakepit.Error.t()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String.t()` | The command to execute on the worker |
| `args` | `map()` | Arguments to pass to the command |
| `opts` | `keyword()` | Optional execution options |

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:pool` | `atom() \| pid()` | `Snakepit.Pool` | The pool to use |
| `:timeout` | `integer()` | `60000` | Request timeout in milliseconds |
| `:session_id` | `String.t()` | `nil` | Execute with session affinity |

**Returns:**
- `{:ok, result}` - Command executed successfully
- `{:error, %Snakepit.Error{}}` - Execution failed

---

### execute_in_session/4

Executes a command with session-based worker affinity. Subsequent calls with the same `session_id` prefer the same worker for state continuity.

```elixir
@spec execute_in_session(session_id(), command(), args(), keyword()) ::
        {:ok, result()} | {:error, Snakepit.Error.t()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `session_id` | `String.t()` | Unique session identifier |
| `command` | `String.t()` | The command to execute |
| `args` | `map()` | Arguments to pass to the command |
| `opts` | `keyword()` | Optional execution options (same as `execute/3`) |

**Returns:**
- `{:ok, result}` - Command executed successfully
- `{:error, %Snakepit.Error{}}` - Execution failed

---

### execute_stream/4

Executes a streaming command with a callback function for processing chunks.

```elixir
@spec execute_stream(command(), args(), callback_fn(), keyword()) ::
        :ok | {:error, Snakepit.Error.t()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String.t()` | The streaming command to execute |
| `args` | `map()` | Arguments to pass to the command (default: `%{}`) |
| `callback_fn` | `(term() -> any())` | Function called for each streamed chunk |
| `opts` | `keyword()` | Optional execution options |

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:pool` | `atom() \| pid()` | `Snakepit.Pool` | The pool to use |
| `:timeout` | `integer()` | `300000` | Request timeout in milliseconds |
| `:session_id` | `String.t()` | `nil` | Run in a specific session |

**Returns:**
- `:ok` - Streaming completed successfully
- `{:error, %Snakepit.Error{}}` - Streaming failed

**Note:** Streaming is only supported with gRPC adapters.

---

### execute_in_session_stream/5

Executes a streaming command in a session context with worker affinity.

```elixir
@spec execute_in_session_stream(session_id(), command(), args(), callback_fn(), keyword()) ::
        :ok | {:error, Snakepit.Error.t()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `session_id` | `String.t()` | Unique session identifier |
| `command` | `String.t()` | The streaming command to execute |
| `args` | `map()` | Arguments to pass to the command (default: `%{}`) |
| `callback_fn` | `(term() -> any())` | Function called for each streamed chunk |
| `opts` | `keyword()` | Optional execution options |

**Returns:**
- `:ok` - Streaming completed successfully
- `{:error, %Snakepit.Error{}}` - Streaming failed

---

### get_stats/1

Retrieves pool statistics.

```elixir
@spec get_stats(pool_name()) :: map()
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pool` | `atom() \| pid()` | `Snakepit.Pool` | The pool to query |

**Returns:** A map containing aggregate statistics:
```elixir
%{
  requests: integer(),        # Total requests processed
  queued: integer(),          # Currently queued requests
  errors: integer(),          # Total errors encountered
  queue_timeouts: integer(),  # Requests that timed out in queue
  pool_saturated: integer(),  # Times pool reached max queue size
  workers: integer(),         # Total worker count
  available: integer(),       # Available workers
  busy: integer()             # Busy workers
}
```

---

### list_workers/1

Lists all worker IDs in the pool.

```elixir
@spec list_workers(pool_name()) :: [String.t()]
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pool` | `atom() \| pid()` | `Snakepit.Pool` | The pool to query |

**Returns:** List of worker ID strings.

---

### cleanup/0

Manually triggers cleanup of external worker processes for the current run.

```elixir
@spec cleanup() :: :ok | {:timeout, list()}
```

**Returns:**
- `:ok` - Cleanup completed successfully
- `{:timeout, list()}` - Some processes did not terminate within timeout

**Use Case:** Useful for library embedding or scripts that control the lifecycle directly.

---

### run_as_script/2

Starts the Snakepit application, executes a function, and ensures graceful shutdown.

```elixir
@spec run_as_script((-> any()), keyword()) :: any() | {:error, term()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `fun` | `(-> any())` | Zero-arity function to execute |
| `opts` | `keyword()` | Lifecycle options |

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:timeout` | `integer()` | `15000` | Max time to wait for pool initialization (ms) |
| `:shutdown_timeout` | `integer()` | `15000` | Time to wait for supervisor shutdown (ms) |
| `:cleanup_timeout` | `integer()` | `5000` | Time to wait for worker cleanup (ms) |
| `:restart` | `:auto \| true \| false` | `:auto` | Restart Snakepit if already started |
| `:await_pool` | `boolean()` | `pooling_enabled` setting | Wait for pool readiness |
| `:exit_mode` | `:none \| :halt \| :stop \| :auto` | `:none` | Explicit exit behavior (may also be set via `SNAKEPIT_SCRIPT_EXIT`) |
| `:stop_mode` | `:if_started \| :always \| :never` | `:if_started` | Stop Snakepit only when owned by this call (default) or override |
| `:halt` | `boolean()` | `false` or `SNAKEPIT_SCRIPT_HALT` env | Legacy halt flag (deprecated); maps to `exit_mode: :halt` when `:exit_mode` is unset |

**Returns:**
- The result of the provided function
- `{:error, :pool_initialization_timeout}` if pool fails to initialize

**Use Case:** Recommended for short-lived scripts or Mix tasks to prevent orphaned processes.

---

## Script Lifecycle (0.9.0)

This section is the single source of truth for `run_as_script/2` exit behavior,
shutdown sequencing, and environment variable semantics in 0.9.0.

### Exit Selection Precedence

The runtime resolves the effective `exit_mode` using the first applicable rule
below (highest wins):

| Priority | Source | Input | Effective `exit_mode` | Notes |
|----------|--------|-------|-----------------------|-------|
| 1 | `:exit_mode` option | `:none \| :stop \| :halt \| :auto` | as provided | Invalid atom raises `ArgumentError` |
| 2 | legacy `:halt` option | `true \| false` | `:halt` if `true`; otherwise continue | Only evaluated when `:exit_mode` is unset |
| 3 | `SNAKEPIT_SCRIPT_EXIT` env var | string | parsed value | Only evaluated when `:exit_mode` and `:halt` are unset |
| 4 | legacy `SNAKEPIT_SCRIPT_HALT` env var | truthy string | `:halt` if truthy; otherwise continue | Deprecated in 0.9.0 |
| 5 | default | n/a | `:none` | Return normally after cleanup |

### `SNAKEPIT_SCRIPT_EXIT` parsing rules

- Read only when higher-precedence options do not set an exit mode.
- Parsing is case-insensitive and whitespace-tolerant (trim then lowercase).
- Accepted values: `none`, `halt`, `stop`, `auto`.
- Empty string is treated as unset.
- Invalid value: ignore (treat as unset) and emit a pre-shutdown Logger warning
  that includes the invalid value and the fallback used.

### Legacy `SNAKEPIT_SCRIPT_HALT` compatibility

- Truthy values (after trim + lowercase): `1`, `true`, `yes`, `y`, `on`.
- Any other value is false.
- Deprecated in favor of `SNAKEPIT_SCRIPT_EXIT=halt`.

### Status Code Rules

- If the user function returns normally: `status = 0`.
- If the user function raises/throws/exits: `status = 1` (no IO in the exit path).

Apply `status` as follows:

- `exit_mode: :halt` -> `System.halt(status)` after cleanup.
- `exit_mode: :stop` -> `System.stop(status)` after cleanup; then block the caller
  until VM shutdown completes.
- `exit_mode: :none` -> return/raise normally; Snakepit does not force VM termination.
- `exit_mode: :auto` -> resolve to `:stop` or `:none` per the deterministic rule
  below; then apply the corresponding behavior.

When `exit_mode` is `:none`, errors from the user function are re-raised after shutdown.

### `:auto` resolution rule

`exit_mode: :auto` resolves to `:stop` only when BOTH conditions are true:

- The current `run_as_script/2` invocation started `:snakepit` (owned), and
- The VM is running with `--no-halt` (detected via `:init.get_argument(:no_halt)`).

In all other cases (including embedded usage), `:auto` resolves to `:none`.

### `stop_mode` x `exit_mode` matrix

`stop_mode` controls whether Snakepit (OTP application) stops; `exit_mode`
controls whether the entire VM exits. These are independent axes.

Definitions:

- **Owned**: this `run_as_script/2` invocation started `:snakepit`.
- **Embedded**: `:snakepit` was already running before `run_as_script/2`.
- **Ownership detection**: via the list returned by `Application.ensure_all_started/1`
  (owned when `:snakepit` appears in the "started apps" list).

| Context | stop_mode | exit_mode | Expected behavior | Guidance |
|---------|-----------|-----------|-------------------|----------|
| Standalone (Owned) | `:if_started` (default) | `:none` (default) | Stop Snakepit, run cleanup, return; script runner may exit VM | Recommended for most scripts |
| Standalone (Owned) | `:if_started` | `:stop` | Stop Snakepit, run cleanup, request VM shutdown with status | Recommended for `--no-halt` contexts |
| Standalone (Owned) | `:if_started` | `:halt` | Stop Snakepit, run cleanup, hard halt VM with status | Only for explicit operator intent |
| Standalone (Owned) | `:if_started` | `:auto` | If `--no-halt` present -> behaves as `:stop`; else `:none` | Recommended safe default for scripts under `--no-halt` |
| Embedded (Not owned) | `:if_started` (default) | `:none` | Do not stop Snakepit; run cleanup for this run only; return | Recommended for library embedding |
| Embedded (Not owned) | `:always` | any | Stops Snakepit even though not owned | Strongly discouraged |
| Embedded (Not owned) | any | `:stop` / `:halt` | Stops entire VM | Invalid for embedded usage |
| Embedded (Not owned) | any | `:auto` | MUST resolve to `:none` even if `--no-halt` is present | Guardrail for host safety |

**Warning:** In embedded usage, avoid `exit_mode: :stop` or `:halt` because they
shut down the host VM regardless of `stop_mode`.

### Shutdown State Machine

Implementation must follow this sequence:

1. Resolve `exit_mode` (precedence table) and `stop_mode`.
2. Start Snakepit if needed; record ownership (`owned?`) and capture `run_id`.
3. Optional: await pool readiness (`await_pool`).
4. Execute user function; capture outcome (`status` per Status Code Rules).
5. Shutdown orchestrator:
   a. Emit telemetry `[:snakepit, :script, :shutdown, :start]` with `run_id`,
      `exit_mode`, `stop_mode`, `owned?`, and `status`.
   b. Capture cleanup targets before stopping Snakepit.
   c. Conditional stop: stop Snakepit iff `stop_mode == :always` or
      (`stop_mode == :if_started` and `owned?`); emit `[:snakepit, :script, :shutdown, :stop]`.
   d. Bounded cleanup: run RuntimeCleanup with timeout; idempotent by design;
      emit `[:snakepit, :script, :shutdown, :cleanup]`.
   e. Conditional VM exit:
      - `:halt` -> hard halt (cleanup MUST already be complete).
      - `:stop` -> cooperative VM shutdown (caller blocks until exit).
      - `:none` -> return/raise to caller.
      Emit `[:snakepit, :script, :shutdown, :exit]` before applying the exit decision.

### Telemetry Contract (0.9.0)

Event prefix: `[:snakepit, :script, :shutdown, ...]`

| Event | When | Required metadata |
|-------|------|-------------------|
| `[:snakepit, :script, :shutdown, :start]` | Before cleanup begins | `run_id`, `exit_mode`, `stop_mode`, `owned?`, `status`, `cleanup_result` |
| `[:snakepit, :script, :shutdown, :stop]` | After stop decision | `run_id`, `exit_mode`, `stop_mode`, `owned?`, `status`, `cleanup_result` |
| `[:snakepit, :script, :shutdown, :cleanup]` | After cleanup completes | `run_id`, `exit_mode`, `stop_mode`, `owned?`, `status`, `cleanup_result` |
| `[:snakepit, :script, :shutdown, :exit]` | Before applying the exit decision | `run_id`, `exit_mode`, `stop_mode`, `owned?`, `status`, `cleanup_result` |

Required metadata across all shutdown events:

- `run_id`
- `exit_mode`
- `stop_mode`
- `owned?`
- `status`
- `cleanup_result`

`cleanup_result` values:

- `:pending` for `:start` and `:stop` phases.
- `:ok` when cleanup succeeds.
- `:timeout` when cleanup exceeds its bounded timeout.
- `:skipped` when cleanup is disabled (`cleanup_timeout <= 0`).
- `{:error, reason}` when cleanup crashes.

---

## Configuration Options

Snakepit supports two configuration formats: legacy single-pool and multi-pool (v0.6+).

### Simple (Legacy) Configuration

For backward compatibility with v0.5.x configurations:

```elixir
# config/config.exs
config :snakepit,
  pooling_enabled: true,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pool_size: 100,
  pool_config: %{
    startup_batch_size: 8,
    startup_batch_delay_ms: 750,
    max_workers: 1000
  }
```

In legacy mode, when both top-level `:pool_size` and `pool_config.pool_size`
are present, the top-level `:pool_size` takes precedence.

### Multi-Pool Configuration (v0.6+)

For multiple pools with different profiles:

```elixir
# config/config.exs
config :snakepit,
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 100,
      adapter_module: Snakepit.Adapters.GRPCPython
    },
    %{
      name: :hpc,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 16
    }
  ]
```

### Global Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pooling_enabled` | `boolean()` | `false` | Enable/disable pooling |
| `adapter_module` | `module()` | `nil` | Default adapter module |
| `pool_size` | `pos_integer()` | `System.schedulers_online() * 2` | Default pool size |
| `capacity_strategy` | `:pool \| :profile \| :hybrid` | `:pool` | How worker capacity is managed |
| `pool_startup_timeout` | `integer()` | `10000` | Worker startup timeout (ms) |
| `pool_queue_timeout` | `integer()` | `5000` | Request queue timeout (ms) |
| `pool_max_queue_size` | `integer()` | `1000` | Maximum queued requests |
| `grpc_worker_health_check_timeout_ms` | `integer()` | `5000` | Periodic worker health-check RPC timeout (ms) |

### Per-Pool Configuration Options

#### Required Fields

| Option | Type | Description |
|--------|------|-------------|
| `name` | `atom()` | Pool identifier (required) |

#### Profile Selection

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_profile` | `:process \| :thread` | `:process` | Worker execution profile |

#### Common Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pool_size` | `pos_integer()` | `System.schedulers_online() * 2` | Number of workers |
| `adapter_module` | `module()` | Global setting | Adapter module for this pool |
| `adapter_args` | `list()` | `[]` | CLI arguments for adapter |
| `adapter_env` | `list()` | `[]` | Environment variables for adapter |
| `capacity_strategy` | `:pool \| :profile \| :hybrid` | `:pool` | Capacity management strategy |

#### Process Profile Specific

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `startup_batch_size` | `pos_integer()` | `8` | Workers started per batch |
| `startup_batch_delay_ms` | `non_neg_integer()` | `750` | Delay between batches (ms) |

#### Thread Profile Specific

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `threads_per_worker` | `pos_integer()` | `10` | Thread pool size per worker |
| `thread_safety_checks` | `boolean()` | `false` | Enable runtime thread safety checks |

#### Lifecycle Management

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_ttl` | `:infinity \| {value, unit}` | `:infinity` | Worker time-to-live |
| `worker_max_requests` | `:infinity \| pos_integer()` | `:infinity` | Max requests before recycling |

**TTL Unit Options:** `:seconds`, `:minutes`, `:hours`

### Heartbeat Configuration

Heartbeat configuration can be specified globally or per-pool:

```elixir
# Global heartbeat config
config :snakepit,
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 2000,
    timeout_ms: 10000,
    max_missed_heartbeats: 3,
    initial_delay_ms: 0,
    dependent: true
  }

# Per-pool heartbeat config
%{
  name: :my_pool,
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 5000
  }
}
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | `boolean()` | `true` | Enable heartbeat monitoring |
| `ping_interval_ms` | `integer()` | `2000` | Interval between heartbeat pings |
| `timeout_ms` | `integer()` | `10000` | Heartbeat response timeout |
| `max_missed_heartbeats` | `integer()` | `3` | Missed heartbeats before worker restart |
| `initial_delay_ms` | `integer()` | `0` | Delay before first heartbeat |
| `dependent` | `boolean()` | `true` | Whether heartbeat failure should restart worker |

### Logging Configuration

Snakepit uses a custom logger (`Snakepit.Logger`) that can be configured:

```elixir
config :snakepit,
  log_level: :info  # :debug | :info | :warning | :error
```

---

## Pool API

The `Snakepit.Pool` module provides lower-level pool management functions.

### execute/3

Executes a command on any available worker (same as `Snakepit.execute/3`).

```elixir
@spec execute(command(), args(), keyword()) :: {:ok, result()} | {:error, term()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String.t()` | Command to execute |
| `args` | `map()` | Command arguments |
| `opts` | `keyword()` | Execution options |

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:pool` | `atom() \| pid()` | `Snakepit.Pool` | Pool process |
| `:timeout` | `integer()` | `60000` | Request timeout (ms) |
| `:pool_name` | `atom()` | Default pool | Target pool name |
| `:session_id` | `String.t()` | `nil` | Session for worker affinity |

---

### execute_stream/4

Executes a streaming command with callback.

```elixir
@spec execute_stream(command(), args(), callback_fn(), keyword()) ::
        :ok | {:error, term()}
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String.t()` | Streaming command |
| `args` | `map()` | Command arguments |
| `callback_fn` | `(term() -> any())` | Chunk handler callback |
| `opts` | `keyword()` | Execution options |

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:pool` | `atom() \| pid()` | `Snakepit.Pool` | Pool process |
| `:timeout` | `integer()` | `300000` | Request timeout (ms) |
| `:checkout_timeout` | `integer()` | `5000` | Worker checkout timeout (ms) |
| `:pool_name` | `atom()` | Default pool | Target pool name |
| `:session_id` | `String.t()` | `nil` | Session for worker affinity |

---

### get_stats/1, get_stats/2

Retrieves pool statistics.

```elixir
@spec get_stats(atom() | pid()) :: map()
@spec get_stats(atom() | pid(), atom()) :: map() | {:error, :pool_not_found}
```

**Signatures:**
- `get_stats()` - Stats from all pools (aggregated)
- `get_stats(pool)` - Stats from all pools managed by the given pool process
- `get_stats(pool, pool_name)` - Stats from a specific named pool

**Returns:** Statistics map (see `Snakepit.get_stats/1` for structure).

---

### list_workers/1, list_workers/2

Lists worker IDs in the pool.

```elixir
@spec list_workers(atom() | pid()) :: [String.t()]
@spec list_workers(atom() | pid(), atom()) :: [String.t()] | {:error, :pool_not_found}
```

**Signatures:**
- `list_workers()` - All workers from all pools
- `list_workers(pool)` - All workers from the given pool process
- `list_workers(pool, pool_name)` - Workers from a specific named pool

---

### await_ready/2

Waits for the pool to be fully initialized.

```elixir
@spec await_ready(atom() | pid(), timeout()) :: :ok | {:error, Snakepit.Error.t()}
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pool` | `atom() \| pid()` | `Snakepit.Pool` | Pool process |
| `timeout` | `integer()` | `15000` | Initialization timeout (ms) |

**Returns:**
- `:ok` - All workers are ready
- `{:error, %Snakepit.Error{category: :timeout}}` - Pool did not initialize in time

---

## Working Examples

### Basic Execute Usage

```elixir
# Simple command execution
{:ok, result} = Snakepit.execute("ping", %{message: "hello"})

# With timeout option
{:ok, result} = Snakepit.execute("long_running_task", %{data: payload}, timeout: 120_000)

# Targeting a specific pool (multi-pool setup)
{:ok, result} = Snakepit.execute("compute", %{input: data}, pool_name: :hpc)
```

### Session-Based Execution

```elixir
# Create a session ID (typically from your application context)
session_id = "user_123_session_abc"

# First call - worker is assigned to this session
{:ok, result1} = Snakepit.execute_in_session(session_id, "initialize", %{config: config})

# Subsequent calls prefer the same worker for state continuity
{:ok, result2} = Snakepit.execute_in_session(session_id, "process", %{data: data1})
{:ok, result3} = Snakepit.execute_in_session(session_id, "process", %{data: data2})

# Finalize the session
{:ok, result4} = Snakepit.execute_in_session(session_id, "finalize", %{})
```

### Streaming Execution

```elixir
# Process streaming results with a callback
Snakepit.execute_stream("batch_inference", %{items: large_dataset}, fn chunk ->
  # Handle each chunk as it arrives
  IO.inspect(chunk, label: "Received chunk")
  process_partial_result(chunk)
end, timeout: 600_000)

# Streaming with session affinity
Snakepit.execute_in_session_stream(
  "session_123",
  "generate_report",
  %{template: "quarterly"},
  fn chunk -> send(self(), {:chunk, chunk}) end
)
```

### Getting Pool Stats

```elixir
# Get aggregate stats across all pools
stats = Snakepit.get_stats()
IO.inspect(stats, label: "Pool Statistics")

# Example output:
# %{
#   requests: 15432,
#   queued: 5,
#   errors: 12,
#   queue_timeouts: 3,
#   pool_saturated: 0,
#   workers: 16,
#   available: 11,
#   busy: 5
# }

# Get stats for a specific pool
{:ok, hpc_stats} = Snakepit.Pool.get_stats(Snakepit.Pool, :hpc)

# Monitor pool health in a supervision tree
defmodule MyApp.PoolMonitor do
  use GenServer

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_pools, state) do
    stats = Snakepit.get_stats()

    if stats.available == 0 and stats.queued > 100 do
      Logger.warning("Pool under heavy load: #{inspect(stats)}")
    end

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check, do: Process.send_after(self(), :check_pools, 5_000)
end
```

### Using run_as_script/2

```elixir
# In a Mix task
defmodule Mix.Tasks.MyApp.ProcessData do
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Snakepit.run_as_script(fn ->
      {:ok, result} = Snakepit.execute("process_batch", %{input: args})
      IO.puts("Processing complete: #{inspect(result)}")
    end, timeout: 30_000, cleanup_timeout: 10_000)
  end
end

# For scripts that must exit cleanly
Snakepit.run_as_script(fn ->
  do_work()
end, exit_mode: :auto)

# For embedded usage, never stop the host VM
Snakepit.run_as_script(fn ->
  do_work()
end, exit_mode: :none, stop_mode: :never)
```

### Waiting for Pool Readiness

```elixir
# Wait for pool to be ready before processing
case Snakepit.Pool.await_ready(Snakepit.Pool, 30_000) do
  :ok ->
    Logger.info("Pool is ready, starting processing")
    start_processing()

  {:error, %Snakepit.Error{category: :timeout}} ->
    Logger.error("Pool failed to initialize")
    {:error, :pool_not_ready}
end
```

---

## Configuration API

The `Snakepit.Config` module provides functions for working with pool configurations.

### get_pool_configs/0

Retrieves and validates all pool configurations.

```elixir
@spec get_pool_configs() :: {:ok, [pool_config()]} | {:error, term()}
```

### get_pool_config/1

Retrieves configuration for a specific named pool.

```elixir
@spec get_pool_config(atom()) :: {:ok, pool_config()} | {:error, term()}
```

### validate_pool_config/1

Validates a single pool configuration map.

```elixir
@spec validate_pool_config(map()) :: {:ok, pool_config()} | {:error, term()}
```

### normalize_pool_config/1

Normalizes a pool configuration by filling in defaults.

```elixir
@spec normalize_pool_config(map()) :: pool_config()
```

### thread_profile?/1

Checks if a pool configuration uses the thread profile.

```elixir
@spec thread_profile?(pool_config()) :: boolean()
```

### get_profile_module/1

Returns the profile module for a pool configuration.

```elixir
@spec get_profile_module(pool_config()) :: module()
# Returns: Snakepit.WorkerProfile.Process or Snakepit.WorkerProfile.Thread
```

### heartbeat_defaults/0

Returns the normalized default heartbeat configuration.

```elixir
@spec heartbeat_defaults() :: map()
```

---

## Error Handling

Snakepit uses structured errors via `Snakepit.Error`. Common error categories:

| Category | Description |
|----------|-------------|
| `:timeout` | Operation timed out |
| `:worker` | Worker execution failed |
| `:validation` | Invalid input or configuration |
| `:pool` | Pool-level error (saturated, strict affinity, not found) |

```elixir
case Snakepit.execute("command", %{}) do
  {:ok, result} ->
    handle_success(result)

  {:error, %Snakepit.Error{category: :timeout} = error} ->
    Logger.warning("Request timed out: #{error.message}")

  {:error, %Snakepit.Error{category: :pool, details: %{reason: :pool_saturated}}} ->
    Logger.error("Pool saturated")

  {:error, error} ->
    Logger.error("Unknown error: #{inspect(error)}")
end
```
