# Snakepit Timeout Reference

This document provides a comprehensive reference for all timeout mechanisms in Snakepit.
Understanding these timeouts is critical for configuring your application correctly,
especially when working with long-running operations like LLM calls or batch ML inference.

## Table of Contents

1. [Call Sequence Diagram](#call-sequence-diagram)
2. [Timeout Summary Table](#timeout-summary-table)
3. [Timeout Details by Layer](#timeout-details-by-layer)
4. [Common Scenarios](#common-scenarios)
5. [Configuration Examples](#configuration-examples)

---

## Call Sequence Diagram

The following diagram shows the full call sequence from `Snakepit.execute()` to the gRPC
response, with timeout points marked.

```
User Code                Pool                 GRPCWorker              gRPC Client           Python gRPC Server
    |                      |                       |                       |                       |
    |  Snakepit.execute()  |                       |                       |                       |
    | -------------------> |                       |                       |                       |
    |                      |                       |                       |                       |
    |   [T1: pool_request_timeout]                 |                       |                       |
    |   GenServer.call timeout (default 60s)       |                       |                       |
    |                      |                       |                       |                       |
    |                      |  {:execute, ...}      |                       |                       |
    |                      | --------------------> |                       |                       |
    |                      |                       |                       |                       |
    |                      |       [T2: grpc_worker_execute_timeout]       |                       |
    |                      |       GenServer.call + 1s margin (default 30s)|                       |
    |                      |                       |                       |                       |
    |                      |                       |  execute_tool()       |                       |
    |                      |                       | --------------------> |                       |
    |                      |                       |                       |                       |
    |                      |                       |   [T3: grpc_command_timeout]                  |
    |                      |                       |   gRPC call_opts timeout (default 30s)        |
    |                      |                       |                       |                       |
    |                      |                       |                       |  gRPC Request         |
    |                      |                       |                       | --------------------> |
    |                      |                       |                       |                       |
    |                      |                       |                       |   [Python Processing] |
    |                      |                       |                       |   (No Snakepit        |
    |                      |                       |                       |    timeout control)   |
    |                      |                       |                       |                       |
    |                      |                       |                       |  gRPC Response        |
    |                      |                       |                       | <-------------------- |
    |                      |                       |                       |                       |
    |                      |                       |  {:ok, result}        |                       |
    |                      |                       | <-------------------- |                       |
    |                      |                       |                       |                       |
    |                      |  {:ok, result}        |                       |                       |
    |                      | <-------------------- |                       |                       |
    |                      |                       |                       |                       |
    |  {:ok, result}       |                       |                       |                       |
    | <------------------- |                       |                       |                       |
    |                      |                       |                       |                       |
```

### Timeout Hierarchy

**CRITICAL**: Timeouts are layered. The outermost timeout wins:

```
pool_request_timeout (60s)
    |
    +-- (GenServer.call to Pool)
            |
            +-- grpc_worker_execute_timeout (30s) + 1s margin = 31s
                    |
                    +-- (GenServer.call to GRPCWorker)
                            |
                            +-- grpc_command_timeout (30s)
                                    |
                                    +-- (gRPC call to Python)
```

**Key insight**: If your LLM call takes 60 seconds:
- `grpc_command_timeout` (30s) will trigger FIRST
- The error bubbles up through the layers
- You need to increase timeouts from the innermost layer outward

---

## Timeout Summary Table

| Config Key | Default | Layer | What it controls |
|------------|---------|-------|------------------|
| `pool_request_timeout` | 60,000ms | Pool | GenServer.call to Pool for execute |
| `pool_streaming_timeout` | 300,000ms | Pool | GenServer.call for streaming operations |
| `pool_queue_timeout` | 5,000ms | Pool | How long request waits in queue |
| `checkout_timeout` | 5,000ms | Pool | GenServer.call to checkout worker for streaming |
| `pool_await_ready_timeout` | 15,000ms | Pool | await_ready() waiting for pool initialization |
| `pool_startup_timeout` | 10,000ms | Pool | Task.async_stream timeout for worker startup |
| `grpc_worker_execute_timeout` | 30,000ms | Worker | GenServer.call to GRPCWorker.execute |
| `grpc_worker_stream_timeout` | 300,000ms | Worker | GenServer.call for streaming |
| `grpc_command_timeout` | 30,000ms | Adapter | gRPC call timeout (passed to GRPC.Stub) |
| `grpc_batch_inference_timeout` | 300,000ms | Adapter | gRPC timeout for batch_inference command |
| `grpc_large_dataset_timeout` | 600,000ms | Adapter | gRPC timeout for process_large_dataset |
| `grpc_server_ready_timeout` | 30,000ms | Worker | Wait for Python gRPC server readiness file |
| `worker_ready_timeout` | 30,000ms | Worker | GenServer.call to notify Pool of worker ready |
| `crash_barrier_checkout_timeout` | 5,000ms | Pool | Checkout worker during crash barrier retry |
| `graceful_shutdown_timeout_ms` | 6,000ms | Worker | Python process SIGTERM -> SIGKILL escalation |
| `heartbeat_timeout_ms` | 10,000ms | Heartbeat | gRPC heartbeat call timeout |
| `grpc_client_execute_timeout` | 30,000ms | Client | Default for Client.execute() |
| `cleanup_on_stop_timeout_ms` | 3,000ms | App | Wait for process cleanup on Application.stop |

---

## Timeout Details by Layer

### 1. Pool Layer Timeouts

#### `pool_request_timeout` (default: 60,000ms)

**Config key**: `:pool_request_timeout`

**Where applied**: `Snakepit.Pool.execute/3`
```elixir
# lib/snakepit/pool/pool.ex:81-83
def execute(command, args, opts \\ []) do
  pool = opts[:pool] || __MODULE__
  timeout = opts[:timeout] || Defaults.pool_request_timeout()
  GenServer.call(pool, {:execute, command, args, opts}, timeout)
end
```

**What happens on timeout**: `{:error, {:timeout, {GenServer, :call, ...}}}` raised by GenServer.

**Override per-call**: `Snakepit.execute(cmd, args, timeout: 120_000)`


#### `pool_streaming_timeout` (default: 300,000ms)

**Config key**: `:pool_streaming_timeout`

**Where applied**: `Snakepit.Pool.execute_stream/4`
```elixir
# lib/snakepit/pool/pool.ex:89-91
def execute_stream(command, args, callback_fn, opts \\ []) do
  pool = opts[:pool] || __MODULE__
  timeout = opts[:timeout] || Defaults.pool_streaming_timeout()
  ...
end
```

**What happens on timeout**: GenServer.call timeout during worker checkout or stream setup.


#### `pool_queue_timeout` (default: 5,000ms)

**Config key**: `:pool_queue_timeout`

**Where applied**: `Snakepit.Pool.queue_request/7`
```elixir
# lib/snakepit/pool/pool.ex:1032-1033
timer_ref = Process.send_after(self(), {:queue_timeout, pool_name, from}, pool_state.queue_timeout)
```

**What happens on timeout**: Request removed from queue, `{:error, :queue_timeout}` returned to caller.

**Purpose**: Prevents requests from waiting indefinitely when all workers are busy.


#### `checkout_timeout` (default: 5,000ms)

**Config key**: `:checkout_timeout`

**Where applied**: `Snakepit.Pool.checkout_worker_for_stream/2`
```elixir
# lib/snakepit/pool/pool.ex:127-130
defp checkout_worker_for_stream(pool, opts) do
  timeout = opts[:checkout_timeout] || Defaults.checkout_timeout()
  GenServer.call(pool, {:checkout_worker, opts[:session_id]}, timeout)
end
```

**What happens on timeout**: Streaming operation fails to start.


#### `pool_await_ready_timeout` (default: 15,000ms)

**Config key**: `:pool_await_ready_timeout`

**Where applied**: `Snakepit.Pool.await_ready/2`
```elixir
# lib/snakepit/pool/pool.ex:222-233
def await_ready(pool, timeout) do
  GenServer.call(pool, :await_ready, timeout)
catch
  :exit, {:timeout, _} ->
    {:error, Error.timeout_error("Pool initialization timed out", ...)}
end
```

**What happens on timeout**: `{:error, %Snakepit.Error{category: :timeout}}`.


#### `pool_startup_timeout` (default: 10,000ms)

**Config key**: `:pool_startup_timeout`

**Where applied**: `Snakepit.Pool.start_worker_batches/8`
```elixir
# lib/snakepit/pool/pool.ex:1627-1634
batch
|> Task.async_stream(
  fn i -> start_worker_in_batch(worker_ctx, i) end,
  timeout: startup_timeout,
  max_concurrency: batch_config.size,
  on_timeout: :kill_task
)
```

**What happens on timeout**: Individual worker startup task killed, worker not added to pool.

---

### 2. Worker Layer Timeouts

#### `grpc_worker_execute_timeout` (default: 30,000ms)

**Config key**: `:grpc_worker_execute_timeout`

**Where applied**: `Snakepit.GRPCWorker.execute/4`
```elixir
# lib/snakepit/grpc_worker.ex:132-148
def execute(worker, command, args, nil) do
  execute(worker, command, args, Defaults.grpc_worker_execute_timeout())
end

def execute(worker_id, command, args, timeout) when is_binary(worker_id) do
  case PoolRegistry.get_worker_pid(worker_id) do
    {:ok, pid} ->
      GenServer.call(pid, {:execute, command, args, timeout}, timeout + 1_000)
    ...
  end
end
```

**Note**: The GenServer.call timeout is `timeout + 1_000` (adds 1 second margin).

**What happens on timeout**: GenServer.call timeout, request fails.


#### `grpc_worker_stream_timeout` (default: 300,000ms)

**Config key**: `:grpc_worker_stream_timeout`

**Where applied**: `Snakepit.GRPCWorker.execute_stream/5`
```elixir
# lib/snakepit/grpc_worker.ex:156-180
def execute_stream(worker, command, args, callback_fn, nil) do
  execute_stream(worker, command, args, callback_fn, Defaults.grpc_worker_stream_timeout())
end
```

**What happens on timeout**: Streaming operation fails.


#### `grpc_server_ready_timeout` (default: 30,000ms)

**Config key**: `:grpc_server_ready_timeout`

**Where applied**: `Snakepit.GRPCWorker.handle_continue(:connect_and_wait, ...)`
```elixir
# lib/snakepit/grpc_worker.ex:696
with {:ok, actual_port} <- wait_for_server_ready(state.server_port, state.ready_file,
                                                  Defaults.grpc_server_ready_timeout()),
```

**What happens on timeout**: Worker initialization fails with `{:error, :timeout}`.

**Purpose**: Wait for Python gRPC server to write its ready file with the actual port.


#### `worker_ready_timeout` (default: 30,000ms)

**Config key**: `:worker_ready_timeout`

**Where applied**: `Snakepit.GRPCWorker.notify_pool_ready/2`
```elixir
# lib/snakepit/grpc_worker.ex:1263-1264
defp notify_pool_ready(pool_pid, worker_id) when is_pid(pool_pid) do
  GenServer.call(pool_pid, {:worker_ready, worker_id}, Defaults.worker_ready_timeout())
```

**What happens on timeout**: Worker fails to complete initialization.


#### `graceful_shutdown_timeout_ms` (default: 6,000ms)

**Config key**: `:graceful_shutdown_timeout_ms`

**Where applied**: `Snakepit.GRPCWorker.terminate/2`
```elixir
# lib/snakepit/grpc_worker.ex:1082-1088
defp graceful_shutdown_timeout do
  Application.get_env(
    :snakepit,
    :graceful_shutdown_timeout_ms,
    @default_graceful_shutdown_timeout  # 6000
  )
end
```

**What happens on timeout**: SIGTERM escalates to SIGKILL via ProcessKiller.

**Purpose**: Must be >= Python's shutdown envelope: `server.stop(2s) + wait_for_termination(3s) = 5s`.

---

### 3. gRPC/Adapter Layer Timeouts

#### `grpc_command_timeout` (default: 30,000ms)

**Config key**: `:grpc_command_timeout`

**Where applied**: `Snakepit.Adapters.GRPCPython.grpc_execute/5`
```elixir
# lib/snakepit/adapters/grpc_python.ex:208-223
def grpc_execute(connection, session_id, command, args, nil) do
  grpc_execute(connection, session_id, command, args, Defaults.grpc_command_timeout())
end

def grpc_execute(connection, session_id, command, args, timeout) do
  if grpc_available?() do
    Client.execute_tool(
      connection.channel,
      session_id,
      command,
      args,
      timeout: timeout  # <-- passed to gRPC call_opts
    )
  end
end
```

**Where actually enforced**: `Snakepit.GRPC.ClientImpl.execute_tool/5`
```elixir
# lib/snakepit/grpc/client_impl.ex:380-381
timeout = opts[:timeout] || default_timeout
call_opts = [timeout: timeout]  # passed to GRPC.Stub.execute_tool
```

**What happens on timeout**: gRPC call returns `{:error, %GRPC.RPCError{status: 4}}` (DEADLINE_EXCEEDED).


#### Command-Specific Timeouts

The adapter can return command-specific timeouts:

```elixir
# lib/snakepit/adapters/grpc_python.ex:259-264
def command_timeout("batch_inference", _args), do: Defaults.grpc_batch_inference_timeout()   # 300s
def command_timeout("process_large_dataset", _args), do: Defaults.grpc_large_dataset_timeout()  # 600s
def command_timeout(_command, _args), do: Defaults.grpc_command_timeout()  # 30s
```

**How it's used**: `Snakepit.Pool.get_command_timeout/3` checks adapter for command-specific timeout.

---

### 4. GenServer Call Timeout Pattern

Throughout the codebase, a consistent pattern is used for GenServer.call timeouts:

```elixir
GenServer.call(pid, {:execute, command, args, timeout}, timeout + 1_000)
```

The `timeout + 1_000` margin ensures the GenServer.call doesn't timeout before the
inner operation (e.g., gRPC call) has a chance to timeout cleanly and return an error.

---

## Common Scenarios

### Scenario 1: LLM Call Takes 60 Seconds

**Problem**: Default `grpc_command_timeout` is 30s, so the call times out.

**Solution**: Configure from innermost to outermost:

```elixir
config :snakepit,
  # 1. Inner: gRPC call timeout (must be > 60s)
  grpc_command_timeout: 90_000,

  # 2. Middle: Worker GenServer.call (grpc timeout + margin)
  grpc_worker_execute_timeout: 95_000,

  # 3. Outer: Pool GenServer.call (worker timeout + margin)
  pool_request_timeout: 100_000
```

**Or per-call**:
```elixir
Snakepit.execute("llm_generate", %{prompt: "..."}, timeout: 90_000)
```


### Scenario 2: Streaming Batch Inference (5 minutes)

**Problem**: Default streaming timeout is 300s (5 min), which might be enough.

**Check your config**:
```elixir
config :snakepit,
  pool_streaming_timeout: 600_000,      # 10 min for pool
  grpc_worker_stream_timeout: 600_000   # 10 min for worker
```


### Scenario 3: Pool Initialization Takes Too Long

**Problem**: Starting 50+ workers with heavy model loading.

**Solution**:
```elixir
config :snakepit,
  pool_startup_timeout: 60_000,         # 60s per worker startup
  pool_await_ready_timeout: 300_000,    # 5 min to wait for full pool
  grpc_server_ready_timeout: 60_000     # 60s for Python server ready
```


### Scenario 4: Workers Keep Getting Killed During Shutdown

**Problem**: Python cleanup takes longer than 6 seconds.

**Solution**:
```elixir
config :snakepit,
  graceful_shutdown_timeout_ms: 15_000  # 15 seconds for graceful shutdown
```


### Scenario 5: Requests Queue Too Long

**Problem**: Workers are all busy and requests timeout in queue.

**Solution**:
```elixir
config :snakepit,
  pool_queue_timeout: 10_000,           # Allow 10s queue wait
  pool_max_queue_size: 500              # Or reduce queue size
```

---

## Configuration Examples

### Conservative (Development)

```elixir
# config/dev.exs
config :snakepit,
  pool_request_timeout: 120_000,
  grpc_worker_execute_timeout: 60_000,
  grpc_command_timeout: 60_000,
  pool_queue_timeout: 10_000,
  graceful_shutdown_timeout_ms: 10_000
```

### Production (LLM Workloads)

```elixir
# config/prod.exs
config :snakepit,
  # Generous timeouts for LLM operations
  pool_request_timeout: 300_000,        # 5 min
  pool_streaming_timeout: 600_000,      # 10 min
  grpc_worker_execute_timeout: 290_000, # Just under pool timeout
  grpc_worker_stream_timeout: 590_000,  # Just under pool streaming
  grpc_command_timeout: 280_000,        # Just under worker timeout

  # Fast queue timeout - fail fast if no capacity
  pool_queue_timeout: 2_000,

  # Generous startup for model loading
  pool_startup_timeout: 120_000,
  pool_await_ready_timeout: 600_000,
  grpc_server_ready_timeout: 120_000,

  # Conservative shutdown
  graceful_shutdown_timeout_ms: 10_000
```

### Batch Processing

```elixir
# For batch ML inference jobs
config :snakepit,
  grpc_batch_inference_timeout: 600_000,    # 10 min
  grpc_large_dataset_timeout: 1_800_000,    # 30 min
  pool_streaming_timeout: 1_800_000
```

---

## Debugging Timeout Issues

### 1. Enable Debug Logging

```elixir
config :snakepit, log_level: :debug
```

### 2. Check Which Timeout Fired

Look for these patterns in logs:
- `"** (exit) {:timeout, {GenServer, :call, ..."` - GenServer.call timeout
- `"gRPC error: %GRPC.RPCError{status: 4..."` - gRPC DEADLINE_EXCEEDED
- `"Request timed out after Xms"` - Pool queue timeout
- `"Timeout waiting for Python gRPC server"` - Server ready timeout

### 3. Use Telemetry

```elixir
:telemetry.attach("timeout-debug", [:snakepit, :request, :executed], fn _name, measurements, metadata, _config ->
  if measurements[:duration_us] > 30_000_000 do  # > 30s
    Logger.warning("Slow request: #{metadata.command} took #{measurements[:duration_us] / 1_000}ms")
  end
end, nil)
```

---

## Summary

**Remember the timeout hierarchy**:

1. **Pool timeout** (outermost) - GenServer.call to Pool
2. **Worker timeout** (middle) - GenServer.call to GRPCWorker
3. **gRPC timeout** (innermost) - actual gRPC call to Python

Always configure from **innermost to outermost**, with each outer layer slightly larger:

```
grpc_command_timeout < grpc_worker_execute_timeout < pool_request_timeout
```

If you're seeing timeouts, increase the innermost timeout first, then work outward.
