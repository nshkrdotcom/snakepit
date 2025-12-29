# Hardware Detection and Fault Tolerance

This document covers Snakepit's hardware abstraction layer and fault tolerance mechanisms for building reliable ML workloads.

## Table of Contents

1. [Hardware Detection](#hardware-detection)
2. [Circuit Breaker](#circuit-breaker)
3. [Retry Policies](#retry-policies)
4. [Crash Barrier](#crash-barrier)
5. [Health Monitoring](#health-monitoring)
6. [Executor Helpers](#executor-helpers)
7. [Working Examples](#working-examples)

---

## Hardware Detection

Snakepit provides a unified hardware abstraction layer supporting multiple accelerator backends. The hardware detection system automatically identifies available hardware at startup and caches results for performance.

### Supported Accelerators

| Accelerator | Description | Detection Method |
|-------------|-------------|------------------|
| **CPU** | Always available fallback | Erlang system info |
| **CUDA** | NVIDIA GPUs | `nvidia-smi` queries |
| **MPS** | Apple Metal Performance Shaders | macOS sysctl |
| **ROCm** | AMD GPUs | `rocm-smi` queries |

### `Hardware.detect/0`

Returns comprehensive hardware information as a map.

```elixir
info = Snakepit.Hardware.detect()
```

**Return Structure:**

```elixir
%{
  accelerator: :cuda | :mps | :rocm | :cpu,
  cpu: %{
    cores: 8,
    threads: 16,
    model: "Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz",
    features: [:avx, :avx2, :sse4_1, :sse4_2, :fma],
    memory_total_mb: 32768
  },
  cuda: %{
    version: "12.1",
    driver_version: "535.104.05",
    cudnn_version: "8.9.0",
    devices: [
      %{
        id: 0,
        name: "NVIDIA GeForce RTX 3080",
        memory_total_mb: 10240,
        memory_free_mb: 9800,
        compute_capability: "8.6"
      }
    ]
  } | nil,
  mps: %{
    available: true,
    device_name: "Apple M1 GPU",
    memory_total_mb: 16384
  } | nil,
  rocm: %{
    version: "5.7.0",
    devices: [
      %{
        id: 0,
        name: "AMD Radeon RX 7900 XTX",
        memory_total_mb: 24576,
        memory_free_mb: 24000
      }
    ]
  } | nil,
  platform: "linux-x86_64" | "macos-arm64" | "windows-x86_64"
}
```

The `accelerator` field indicates the primary detected accelerator with priority: CUDA > MPS > ROCm > CPU.

### `Hardware.capabilities/0`

Returns boolean capability flags for quick feature checks.

```elixir
caps = Snakepit.Hardware.capabilities()
```

**Return Structure:**

```elixir
%{
  cuda: true,           # CUDA available
  mps: false,           # Apple MPS available
  rocm: false,          # AMD ROCm available
  avx: true,            # AVX instruction set
  avx2: true,           # AVX2 instruction set
  avx512: false,        # AVX-512 instruction set
  cuda_version: "12.1", # CUDA version string or nil
  cudnn_version: "8.9", # cuDNN version string or nil
  cudnn: true           # cuDNN available
}
```

### `Hardware.select/1`

Selects a device based on preference. Returns `{:ok, device}` or `{:error, :device_not_available}`.

```elixir
# Auto-select best available accelerator
{:ok, device} = Snakepit.Hardware.select(:auto)
# => {:ok, {:cuda, 0}} on CUDA system
# => {:ok, :mps} on Apple Silicon
# => {:ok, :cpu} if no GPU

# Request specific device types
{:ok, {:cuda, 0}} = Snakepit.Hardware.select(:cuda)
{:ok, :mps} = Snakepit.Hardware.select(:mps)
{:ok, {:rocm, 0}} = Snakepit.Hardware.select(:rocm)
{:ok, :cpu} = Snakepit.Hardware.select(:cpu)

# Request specific CUDA device by ID
{:ok, {:cuda, 1}} = Snakepit.Hardware.select({:cuda, 1})
```

**Device Preference Options:**

| Option | Description |
|--------|-------------|
| `:auto` | Automatically select best available accelerator |
| `:cpu` | Select CPU (always succeeds) |
| `:cuda` | Select CUDA device 0 |
| `:mps` | Select Apple MPS |
| `:rocm` | Select ROCm device 0 |
| `{:cuda, id}` | Select specific CUDA device |
| `{:rocm, id}` | Select specific ROCm device |

### `Hardware.select_with_fallback/1`

Tries each device preference in order until one is available. Useful for graceful degradation.

```elixir
# Prefer CUDA, fall back to MPS, then CPU
{:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])

# Returns first available device
# On CUDA system: {:ok, {:cuda, 0}}
# On Apple Silicon: {:ok, :mps}
# On CPU-only: {:ok, :cpu}

# Returns error only if no devices match
{:error, :no_device} = Snakepit.Hardware.select_with_fallback([])
```

### `Hardware.device_info/1`

Returns detailed information about a selected device.

```elixir
info = Snakepit.Hardware.device_info({:cuda, 0})
# => %{
#      type: :cuda,
#      device_id: 0,
#      name: "NVIDIA GeForce RTX 3080",
#      memory_total_mb: 10240,
#      memory_free_mb: 9800,
#      cuda_version: "12.1",
#      compute_capability: "8.6"
#    }

info = Snakepit.Hardware.device_info(:cpu)
# => %{
#      type: :cpu,
#      name: "Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz",
#      cores: 8,
#      threads: 16,
#      memory_mb: 32768
#    }
```

### `Hardware.identity/0`

Returns a hardware identity map suitable for lock file generation.

```elixir
identity = Snakepit.Hardware.identity()
# => %{
#      "platform" => "linux-x86_64",
#      "accelerator" => "cuda",
#      "cpu_features" => ["avx", "avx2", "sse4_1"],
#      "gpu_count" => 2
#    }

# Serialize for lock files
Jason.encode!(identity)
```

### `Hardware.clear_cache/0`

Clears the hardware detection cache, forcing re-detection on the next call.

```elixir
Snakepit.Hardware.clear_cache()
:ok
```

---

## Circuit Breaker

The `Snakepit.CircuitBreaker` module implements the circuit breaker pattern to prevent cascading failures when workers experience issues.

### States

| State | Description |
|-------|-------------|
| **`:closed`** | Normal operation. All calls are allowed through. |
| **`:open`** | Failure threshold exceeded. All calls are rejected with `{:error, :circuit_open}`. |
| **`:half_open`** | Testing recovery. Limited calls allowed to probe if service has recovered. |

### State Transitions

```
         success
    +---------------+
    |               |
    v    failure    |
 CLOSED ---------> OPEN
    ^               |
    |   timeout     v
    +---------- HALF_OPEN
      success      |
                   | failure
                   v
                 OPEN
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | `nil` | GenServer registration name |
| `:failure_threshold` | `5` | Failures before opening circuit |
| `:reset_timeout_ms` | `30000` | Time before transitioning to half-open |
| `:half_open_max_calls` | `1` | Max calls allowed in half-open state |

### API

#### `start_link/1`

Starts a circuit breaker process.

```elixir
{:ok, cb} = Snakepit.CircuitBreaker.start_link(
  name: :my_circuit_breaker,
  failure_threshold: 5,
  reset_timeout_ms: 30_000,
  half_open_max_calls: 1
)
```

#### `call/2`

Executes a function through the circuit breaker.

```elixir
case Snakepit.CircuitBreaker.call(cb, fn -> risky_operation() end) do
  {:ok, result} -> handle_success(result)
  {:error, :circuit_open} -> handle_circuit_open()
  {:error, reason} -> handle_error(reason)
end
```

The circuit breaker automatically:
- Records successes for `{:ok, _}` results
- Records failures for `{:error, _}` results and exceptions
- Rejects calls when circuit is open

#### `state/1`

Returns the current circuit state.

```elixir
state = Snakepit.CircuitBreaker.state(cb)
# => :closed | :open | :half_open
```

#### `stats/1`

Returns circuit breaker statistics.

```elixir
stats = Snakepit.CircuitBreaker.stats(cb)
# => %{
#      state: :closed,
#      failure_count: 2,
#      success_count: 150,
#      failure_threshold: 5,
#      half_open_calls: 0
#    }
```

#### `reset/1`

Manually resets the circuit breaker to closed state.

```elixir
Snakepit.CircuitBreaker.reset(cb)
```

#### `allow_call?/1`

Checks if a call would be allowed without executing.

```elixir
if Snakepit.CircuitBreaker.allow_call?(cb) do
  # Safe to proceed
end
```

#### `record_success/1` and `record_failure/1`

Manually record outcomes (useful for external monitoring).

```elixir
Snakepit.CircuitBreaker.record_success(cb)
Snakepit.CircuitBreaker.record_failure(cb)
```

### Telemetry Events

The circuit breaker emits telemetry events for monitoring:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:snakepit, :circuit_breaker, :opened]` | `%{failure_count: n}` | `%{pool: name, reason: :failures}` |
| `[:snakepit, :circuit_breaker, :closed]` | `%{}` | `%{pool: name}` |
| `[:snakepit, :circuit_breaker, :half_open]` | `%{}` | `%{pool: name}` |

---

## Retry Policies

The `Snakepit.RetryPolicy` module provides configurable retry behavior with exponential backoff and jitter.

### `RetryPolicy.new/1`

Creates a new retry policy.

```elixir
policy = Snakepit.RetryPolicy.new(
  max_attempts: 3,
  backoff_ms: [100, 200, 400],
  jitter: true,
  retriable_errors: [:timeout, :unavailable]
)
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_attempts` | `3` | Maximum number of retry attempts |
| `:backoff_ms` | `[100, 200, 400, 800, 1600]` | List of backoff delays per attempt |
| `:base_backoff_ms` | `100` | Base delay for exponential calculation |
| `:backoff_multiplier` | `2.0` | Multiplier for exponential backoff |
| `:max_backoff_ms` | `30000` | Maximum backoff delay cap |
| `:jitter` | `false` | Enable random jitter |
| `:jitter_factor` | `0.25` | Jitter range as fraction of delay |
| `:retriable_errors` | `[:timeout, :unavailable, :connection_refused, :worker_crash]` | Error atoms to retry, or `:all` |

### API

#### `should_retry?/2`

Checks if another retry attempt should be made.

```elixir
if Snakepit.RetryPolicy.should_retry?(policy, attempt) do
  # More retries available
end
```

#### `retry_for_error?/2`

Checks if an error is retriable according to the policy.

```elixir
Snakepit.RetryPolicy.retry_for_error?(policy, {:error, :timeout})
# => true

Snakepit.RetryPolicy.retry_for_error?(policy, {:error, :invalid_input})
# => false (not in retriable_errors list)
```

#### `backoff_for_attempt/2`

Returns the backoff delay for a given attempt number.

```elixir
delay = Snakepit.RetryPolicy.backoff_for_attempt(policy, 1)
# => 100 (first attempt)

delay = Snakepit.RetryPolicy.backoff_for_attempt(policy, 3)
# => 400 (third attempt, with jitter if enabled)
```

### Exponential Backoff with Jitter

When jitter is enabled, the delay is randomized within the jitter factor range:

```
delay = base_delay +/- (base_delay * jitter_factor)
```

For a 100ms delay with 0.25 jitter factor: delay will be 75-125ms.

---

## Crash Barrier

The `Snakepit.CrashBarrier` module classifies worker crashes, taints unstable workers, and determines retry eligibility.

### Configuration

```elixir
# In config/config.exs
config :snakepit, :crash_barrier,
  enabled: true,
  retry: :idempotent,
  max_restarts: 1,
  taint_duration_ms: 60_000,
  backoff_ms: [50, 100, 200],
  mark_on: [:segfault, :oom, :gpu],
  taint_device_on_cuda_fatal: true
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `:enabled` | `false` | Enable crash barrier |
| `:retry` | `:idempotent` | Retry policy: `:always`, `:idempotent`, or `:never` |
| `:max_restarts` | `1` | Maximum restart attempts |
| `:taint_duration_ms` | `60000` | How long workers remain tainted |
| `:backoff_ms` | `[50, 100, 200]` | Backoff delays between retries |
| `:mark_on` | `[:segfault, :oom, :gpu]` | Crash types that trigger tainting |
| `:taint_on_exit_codes` | `[]` | Specific exit codes to taint |
| `:taint_on_error_types` | `[]` | Error type strings to match |
| `:taint_device_on_cuda_fatal` | `true` | Taint CUDA device on fatal errors |

### Crash Classification

| Classification | Exit Codes | Description |
|----------------|------------|-------------|
| `:segfault` | 139 | Segmentation fault |
| `:abort` | 134 | Process abort |
| `:oom` | 137 | Out of memory |
| `:gpu` | - | GPU/CUDA errors (detected by string matching) |
| `:unknown` | - | Unclassified crashes |

### API

#### `config/1`

Gets the merged crash barrier configuration.

```elixir
config = Snakepit.CrashBarrier.config(pool_config)
```

#### `crash_info/2`

Extracts and classifies crash information.

```elixir
case Snakepit.CrashBarrier.crash_info(result, config) do
  {:ok, %{reason: reason, exit_code: code, classification: :segfault}} ->
    # Handle segfault
  :error ->
    # Not a crash or not taintable
end
```

#### `retry_allowed?/3`

Checks if retry is allowed based on configuration and idempotency.

```elixir
Snakepit.CrashBarrier.retry_allowed?(config, idempotent?, attempt)
# => true | false
```

#### `taint_worker/4`

Taints a worker after a crash.

```elixir
Snakepit.CrashBarrier.taint_worker(pool_name, worker_id, crash_info, config)
```

#### `worker_tainted?/1`

Checks if a worker is currently tainted.

```elixir
Snakepit.CrashBarrier.worker_tainted?(worker_id)
# => true | false
```

---

## Health Monitoring

The `Snakepit.HealthMonitor` module tracks worker health and crash patterns within a rolling window.

### `start_link/1`

Starts a health monitor.

```elixir
{:ok, hm} = Snakepit.HealthMonitor.start_link(
  name: :my_pool_health,
  pool: :default,
  max_crashes: 10,
  crash_window_ms: 60_000,
  check_interval_ms: 30_000
)
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | **required** | GenServer registration name |
| `:pool` | **required** | Pool name to monitor |
| `:max_crashes` | `10` | Max crashes before unhealthy |
| `:crash_window_ms` | `60000` | Rolling window for crash counting |
| `:check_interval_ms` | `30000` | Cleanup interval |

### API

#### `record_crash/3`

Records a worker crash.

```elixir
Snakepit.HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})
```

#### `healthy?/1`

Returns whether the pool is considered healthy.

```elixir
if Snakepit.HealthMonitor.healthy?(hm) do
  # Pool is healthy, crashes within threshold
else
  # Too many crashes, consider taking action
end
```

#### `worker_health/2`

Returns health status for a specific worker.

```elixir
health = Snakepit.HealthMonitor.worker_health(hm, "worker_1")
# => %{
#      healthy: false,
#      crash_count: 5,
#      last_crash_time: 1703836800000
#    }
```

#### `stats/1`

Returns comprehensive health statistics.

```elixir
stats = Snakepit.HealthMonitor.stats(hm)
# => %{
#      pool: :default,
#      total_crashes: 15,
#      crashes_in_window: 3,
#      workers_with_crashes: 2,
#      max_crashes: 10,
#      crash_window_ms: 60000,
#      is_healthy: true
#    }
```

### Telemetry Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:snakepit, :worker, :crash]` | `%{}` | `%{pool: name, worker_id: id, reason: reason}` |

---

## Executor Helpers

The `Snakepit.Executor` module provides various execution strategies for running operations with fault tolerance.

### `execute_with_timeout/2`

Executes a function with a timeout. Returns `{:error, :timeout}` if the function does not complete in time.

```elixir
result = Snakepit.Executor.execute_with_timeout(
  fn -> slow_operation() end,
  timeout_ms: 5000
)

case result do
  {:ok, value} -> handle_success(value)
  {:error, :timeout} -> handle_timeout()
end
```

**Options:**

| Option | Required | Description |
|--------|----------|-------------|
| `:timeout_ms` | Yes | Timeout in milliseconds |

### `execute_with_retry/2`

Executes a function with automatic retry on transient failures.

```elixir
result = Snakepit.Executor.execute_with_retry(
  fn -> external_api_call() end,
  max_attempts: 3,
  backoff_ms: [100, 200, 400],
  jitter: true,
  retriable_errors: [:timeout, :unavailable]
)
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `:max_attempts` | `3` | Maximum retry attempts |
| `:backoff_ms` | `[100, 200, 400]` | Backoff delays |
| `:retriable_errors` | `[:timeout, :unavailable]` | Errors to retry |
| `:jitter` | `false` | Add random jitter |

### `execute_with_circuit_breaker/3`

Executes a function through a circuit breaker.

```elixir
{:ok, cb} = Snakepit.CircuitBreaker.start_link(failure_threshold: 5)

result = Snakepit.Executor.execute_with_circuit_breaker(cb, fn ->
  external_service_call()
end)

case result do
  {:ok, value} -> handle_success(value)
  {:error, :circuit_open} -> handle_circuit_open()
  {:error, reason} -> handle_error(reason)
end
```

### `execute_with_protection/3`

Combines retry logic with circuit breaker protection.

```elixir
{:ok, cb} = Snakepit.CircuitBreaker.start_link(failure_threshold: 5)

result = Snakepit.Executor.execute_with_protection(cb,
  fn -> risky_operation() end,
  max_attempts: 3,
  backoff_ms: [100, 200, 400]
)
```

This wraps the circuit breaker call with retry logic, providing defense in depth.

### `execute_batch/2`

Executes multiple functions in parallel.

```elixir
functions = [
  fn -> fetch_user(1) end,
  fn -> fetch_user(2) end,
  fn -> fetch_user(3) end
]

results = Snakepit.Executor.execute_batch(functions,
  timeout_ms: 10_000,
  max_concurrency: 5
)

# Results in same order as input functions
# => [{:ok, user1}, {:ok, user2}, {:error, :not_found}]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `:timeout_ms` | `30000` | Timeout for all operations |
| `:max_concurrency` | `length(functions)` | Maximum concurrent operations |

### `execute_async/2`

Executes a function asynchronously, returning a Task.

```elixir
task = Snakepit.Executor.execute_async(fn -> slow_computation() end)

# Do other work...

result = Task.await(task)
```

### Telemetry Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:snakepit, :retry, :attempt]` | `%{attempt: n, delay_ms: ms}` | `%{pool: nil, operation: nil}` |
| `[:snakepit, :retry, :success]` | `%{attempts: n, total_duration: ms}` | `%{pool: nil}` |
| `[:snakepit, :retry, :exhausted]` | `%{attempts: n, total_duration: ms}` | `%{pool: nil, last_error: error}` |

---

## Working Examples

### Example 1: Hardware-Aware Device Selection

```elixir
defmodule MyApp.MLWorker do
  alias Snakepit.Hardware

  def select_device do
    # Check capabilities first
    caps = Hardware.capabilities()

    cond do
      caps.cuda and caps.cudnn ->
        # Prefer CUDA with cuDNN for deep learning
        Hardware.select(:cuda)

      caps.mps ->
        # Apple Silicon fallback
        Hardware.select(:mps)

      caps.avx2 ->
        # Optimized CPU path
        {:ok, :cpu}

      true ->
        # Basic CPU
        {:ok, :cpu}
    end
  end

  def run_inference(model, input) do
    {:ok, device} = select_device()
    device_info = Hardware.device_info(device)

    IO.puts("Running on #{device_info.name}")

    # Pass device to Python worker
    Snakepit.call(:ml_pool, "inference", %{
      model: model,
      input: input,
      device: format_device(device)
    })
  end

  defp format_device(:cpu), do: "cpu"
  defp format_device(:mps), do: "mps"
  defp format_device({:cuda, id}), do: "cuda:#{id}"
  defp format_device({:rocm, id}), do: "rocm:#{id}"
end
```

### Example 2: Circuit Breaker for External Services

```elixir
defmodule MyApp.ExternalService do
  alias Snakepit.{CircuitBreaker, Executor}

  def start_link do
    CircuitBreaker.start_link(
      name: :external_api_cb,
      failure_threshold: 5,
      reset_timeout_ms: 30_000
    )
  end

  def call_external_api(params) do
    Executor.execute_with_protection(:external_api_cb,
      fn -> do_api_call(params) end,
      max_attempts: 3,
      backoff_ms: [100, 500, 1000],
      jitter: true
    )
  end

  defp do_api_call(params) do
    case HTTPoison.post("https://api.example.com", params) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status_code: 503}} ->
        {:error, :unavailable}

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def check_health do
    state = CircuitBreaker.state(:external_api_cb)
    stats = CircuitBreaker.stats(:external_api_cb)

    %{
      available: state != :open,
      state: state,
      failure_rate: stats.failure_count / max(stats.success_count + stats.failure_count, 1)
    }
  end
end
```

### Example 3: Batch Processing with Timeouts

```elixir
defmodule MyApp.BatchProcessor do
  alias Snakepit.Executor

  def process_batch(items, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    concurrency = Keyword.get(opts, :max_concurrency, 10)

    functions = Enum.map(items, fn item ->
      fn -> process_item(item) end
    end)

    results = Executor.execute_batch(functions,
      timeout_ms: timeout,
      max_concurrency: concurrency
    )

    # Separate successes and failures
    {successes, failures} = Enum.split_with(results, fn
      {:ok, _} -> true
      _ -> false
    end)

    %{
      total: length(items),
      succeeded: length(successes),
      failed: length(failures),
      results: results
    }
  end

  defp process_item(item) do
    Executor.execute_with_timeout(
      fn -> Snakepit.call(:worker_pool, "process", item) end,
      timeout_ms: 5000
    )
  end
end
```

### Example 4: Health-Based Load Balancing

```elixir
defmodule MyApp.HealthAwarePool do
  alias Snakepit.{HealthMonitor, CircuitBreaker}

  def start_link(pool_name) do
    # Start health monitor
    {:ok, _} = HealthMonitor.start_link(
      name: health_monitor_name(pool_name),
      pool: pool_name,
      max_crashes: 10,
      crash_window_ms: 60_000
    )

    # Start circuit breaker
    {:ok, _} = CircuitBreaker.start_link(
      name: circuit_breaker_name(pool_name),
      failure_threshold: 5,
      reset_timeout_ms: 30_000
    )

    :ok
  end

  def execute(pool_name, fun) do
    cb = circuit_breaker_name(pool_name)
    hm = health_monitor_name(pool_name)

    # Check if pool is healthy before proceeding
    unless HealthMonitor.healthy?(hm) do
      IO.warn("Pool #{pool_name} is unhealthy, proceeding with caution")
    end

    result = CircuitBreaker.call(cb, fun)

    # Record crashes to health monitor
    case result do
      {:error, {:worker_crash, info}} ->
        HealthMonitor.record_crash(hm, info.worker_id, %{reason: info.reason})
        result

      _ ->
        result
    end
  end

  def pool_status(pool_name) do
    hm = health_monitor_name(pool_name)
    cb = circuit_breaker_name(pool_name)

    %{
      health: HealthMonitor.stats(hm),
      circuit_breaker: CircuitBreaker.stats(cb)
    }
  end

  defp health_monitor_name(pool), do: :"#{pool}_health"
  defp circuit_breaker_name(pool), do: :"#{pool}_cb"
end
```

### Example 5: Retry with Custom Error Handling

```elixir
defmodule MyApp.ResilientWorker do
  alias Snakepit.{RetryPolicy, Executor}

  @doc """
  Executes a Python ML task with comprehensive error handling.
  """
  def run_ml_task(task, input) do
    policy = RetryPolicy.new(
      max_attempts: 3,
      backoff_ms: [500, 1000, 2000],
      jitter: true,
      retriable_errors: [:timeout, :worker_crash, :gpu_oom]
    )

    do_with_retry(task, input, policy, 1)
  end

  defp do_with_retry(task, input, policy, attempt) do
    result = Executor.execute_with_timeout(
      fn -> Snakepit.call(:ml_pool, task, input) end,
      timeout_ms: 30_000
    )

    case classify_result(result) do
      {:ok, value} ->
        {:ok, value}

      {:retriable, error} when RetryPolicy.should_retry?(policy, attempt) ->
        delay = RetryPolicy.backoff_for_attempt(policy, attempt)
        IO.puts("Attempt #{attempt} failed with #{inspect(error)}, retrying in #{delay}ms")
        Process.sleep(delay)
        do_with_retry(task, input, policy, attempt + 1)

      {:retriable, error} ->
        {:error, {:max_retries_exceeded, error}}

      {:fatal, error} ->
        {:error, error}
    end
  end

  defp classify_result({:ok, value}), do: {:ok, value}
  defp classify_result({:error, :timeout}), do: {:retriable, :timeout}
  defp classify_result({:error, :worker_crash}), do: {:retriable, :worker_crash}
  defp classify_result({:error, {:gpu_error, "out of memory" <> _}}), do: {:retriable, :gpu_oom}
  defp classify_result({:error, reason}), do: {:fatal, reason}
end
```

### Example 6: Lock File Generation with Hardware Identity

```elixir
defmodule MyApp.LockFile do
  alias Snakepit.Hardware

  @doc """
  Generates a lock file with hardware and dependency information.
  """
  def generate(deps) do
    hardware_id = Hardware.identity()

    lock_content = %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "hardware" => hardware_id,
      "dependencies" => deps,
      "compatibility" => compute_compatibility(hardware_id)
    }

    Jason.encode!(lock_content, pretty: true)
  end

  defp compute_compatibility(hardware_id) do
    %{
      "cuda_required" => hardware_id["accelerator"] == "cuda",
      "min_gpu_count" => hardware_id["gpu_count"],
      "cpu_features" => hardware_id["cpu_features"]
    }
  end

  @doc """
  Validates current hardware against a lock file.
  """
  def validate(lock_path) do
    {:ok, content} = File.read(lock_path)
    lock = Jason.decode!(content)
    current = Hardware.identity()

    cond do
      lock["hardware"]["accelerator"] != current["accelerator"] ->
        {:error, :accelerator_mismatch}

      lock["hardware"]["gpu_count"] > current["gpu_count"] ->
        {:error, :insufficient_gpus}

      not compatible_features?(lock["hardware"]["cpu_features"], current["cpu_features"]) ->
        {:error, :missing_cpu_features}

      true ->
        :ok
    end
  end

  defp compatible_features?(required, available) do
    Enum.all?(required, &(&1 in available))
  end
end
```

---

## Summary

Snakepit provides a comprehensive hardware abstraction and fault tolerance layer:

| Component | Purpose |
|-----------|---------|
| **Hardware** | Unified hardware detection and device selection |
| **CircuitBreaker** | Prevents cascading failures |
| **RetryPolicy** | Configurable retry with exponential backoff |
| **CrashBarrier** | Crash classification and worker tainting |
| **HealthMonitor** | Rolling window crash tracking |
| **Executor** | Convenience wrappers combining fault tolerance patterns |

These components work together to build resilient ML workloads that gracefully handle hardware variations and transient failures.
