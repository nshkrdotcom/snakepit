# Fault Tolerance

Snakepit provides fault tolerance mechanisms to build resilient applications that gracefully handle worker failures and transient errors.

## Overview

| Component | Purpose |
|-----------|---------|
| **CircuitBreaker** | Prevents cascading failures by stopping calls to failing services |
| **RetryPolicy** | Configurable retry with exponential backoff and jitter |
| **HealthMonitor** | Tracks worker crashes within a rolling time window |
| **Executor** | Convenience wrappers combining fault tolerance patterns |

## Circuit Breaker

The `Snakepit.CircuitBreaker` implements the circuit breaker pattern to prevent cascading failures.

### States

| State | Description |
|-------|-------------|
| `:closed` | Normal operation. All calls allowed. |
| `:open` | Threshold exceeded. Calls rejected with `{:error, :circuit_open}`. |
| `:half_open` | Testing recovery. Limited probe calls allowed. |

### Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | `nil` | GenServer registration name |
| `:failure_threshold` | `5` | Failures before opening |
| `:reset_timeout_ms` | `30000` | Time before half-open |
| `:half_open_max_calls` | `1` | Probe calls in half-open |

### API

```elixir
# Start circuit breaker
{:ok, cb} = Snakepit.CircuitBreaker.start_link(
  name: :my_cb, failure_threshold: 5, reset_timeout_ms: 30_000
)

# Execute through circuit breaker
case Snakepit.CircuitBreaker.call(cb, fn -> risky_operation() end) do
  {:ok, result} -> handle_success(result)
  {:error, :circuit_open} -> handle_circuit_open()
  {:error, reason} -> handle_error(reason)
end

# Check state and stats
state = Snakepit.CircuitBreaker.state(cb)  # => :closed | :open | :half_open
stats = Snakepit.CircuitBreaker.stats(cb)
# => %{state: :closed, failure_count: 2, success_count: 150, failure_threshold: 5}

# Manual reset
Snakepit.CircuitBreaker.reset(cb)
```

### Example

```elixir
defmodule MyApp.ExternalService do
  alias Snakepit.CircuitBreaker

  def start_link do
    CircuitBreaker.start_link(name: :api_cb, failure_threshold: 5, reset_timeout_ms: 30_000)
  end

  def call_api(params) do
    case CircuitBreaker.call(:api_cb, fn -> do_api_call(params) end) do
      {:ok, result} -> {:ok, result}
      {:error, :circuit_open} -> {:ok, get_cached_result(params)}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Retry Policies

The `Snakepit.RetryPolicy` provides configurable retry behavior with exponential backoff.

### RetryPolicy.new/1

| Option | Default | Description |
|--------|---------|-------------|
| `:max_attempts` | `3` | Maximum retry attempts |
| `:backoff_ms` | `[100, 200, 400, 800, 1600]` | Backoff delays per attempt |
| `:base_backoff_ms` | `100` | Base delay for exponential calculation |
| `:backoff_multiplier` | `2.0` | Multiplier for exponential backoff |
| `:max_backoff_ms` | `30000` | Maximum backoff cap |
| `:jitter` | `false` | Enable random jitter |
| `:jitter_factor` | `0.25` | Jitter range as fraction of delay |
| `:retriable_errors` | `[:timeout, :unavailable, :connection_refused, :worker_crash]` | Errors to retry |

### API

```elixir
policy = Snakepit.RetryPolicy.new(
  max_attempts: 3, backoff_ms: [100, 200, 400], jitter: true,
  retriable_errors: [:timeout, :unavailable]
)

Snakepit.RetryPolicy.should_retry?(policy, attempt)      # More retries available?
Snakepit.RetryPolicy.retry_for_error?(policy, error)     # Is error retriable?
Snakepit.RetryPolicy.backoff_for_attempt(policy, attempt) # Get delay for attempt
```

### Exponential Backoff with Jitter

With jitter enabled: `delay = base_delay +/- (base_delay * jitter_factor)`

For 100ms delay with 0.25 jitter: actual delay is 75-125ms. This prevents "thundering herd" problems.

### Example

```elixir
defmodule MyApp.ResilientClient do
  alias Snakepit.RetryPolicy

  def fetch_with_retry(url) do
    policy = RetryPolicy.new(max_attempts: 3, backoff_ms: [100, 200, 400], jitter: true)
    do_fetch(url, policy, 1)
  end

  defp do_fetch(url, policy, attempt) do
    case HTTPoison.get(url) do
      {:ok, response} -> {:ok, response}
      {:error, _} = error ->
        if RetryPolicy.should_retry?(policy, attempt) and RetryPolicy.retry_for_error?(policy, error) do
          Process.sleep(RetryPolicy.backoff_for_attempt(policy, attempt))
          do_fetch(url, policy, attempt + 1)
        else
          error
        end
    end
  end
end
```

## Health Monitoring

The `Snakepit.HealthMonitor` tracks crashes within a rolling window.

### Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | **required** | GenServer registration name |
| `:pool` | **required** | Pool name to monitor |
| `:max_crashes` | `10` | Max crashes before unhealthy |
| `:crash_window_ms` | `60000` | Rolling window duration |
| `:check_interval_ms` | `30000` | Cleanup interval |

### API

```elixir
{:ok, hm} = Snakepit.HealthMonitor.start_link(
  name: :pool_health, pool: :default, max_crashes: 10, crash_window_ms: 60_000
)

Snakepit.HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})
Snakepit.HealthMonitor.healthy?(hm)  # => true | false

stats = Snakepit.HealthMonitor.stats(hm)
# => %{pool: :default, total_crashes: 15, crashes_in_window: 3, is_healthy: true}

health = Snakepit.HealthMonitor.worker_health(hm, "worker_1")
# => %{healthy: false, crash_count: 5, last_crash_time: 1703836800000}
```

### Example

```elixir
defmodule MyApp.HealthAwarePool do
  alias Snakepit.HealthMonitor

  def execute_with_health_check(pool_name, fun) do
    hm = :"#{pool_name}_health"
    unless HealthMonitor.healthy?(hm), do: Logger.warning("Pool unhealthy")

    case fun.() do
      {:error, {:worker_crash, info}} = error ->
        HealthMonitor.record_crash(hm, info.worker_id, %{reason: info.reason})
        error
      result -> result
    end
  end
end
```

## Executor Helpers

The `Snakepit.Executor` provides convenience wrappers.

### execute_with_timeout/2

```elixir
result = Snakepit.Executor.execute_with_timeout(fn -> slow_op() end, timeout_ms: 5000)
# => {:ok, value} | {:error, :timeout}
```

### execute_with_retry/2

```elixir
result = Snakepit.Executor.execute_with_retry(fn -> api_call() end,
  max_attempts: 3, backoff_ms: [100, 200, 400], jitter: true
)
```

### execute_with_protection/3

Combines retry with circuit breaker for defense in depth.

```elixir
{:ok, cb} = Snakepit.CircuitBreaker.start_link(failure_threshold: 5)

result = Snakepit.Executor.execute_with_protection(cb, fn -> risky_op() end,
  max_attempts: 3, backoff_ms: [100, 200, 400]
)
```

### execute_batch/2

Executes multiple functions in parallel.

```elixir
functions = [fn -> fetch(1) end, fn -> fetch(2) end, fn -> fetch(3) end]
results = Snakepit.Executor.execute_batch(functions, timeout_ms: 10_000, max_concurrency: 5)
# => [{:ok, r1}, {:ok, r2}, {:error, :not_found}]
```

## Combined Protection Example

```elixir
defmodule MyApp.ResilientService do
  alias Snakepit.{CircuitBreaker, Executor}

  def start_link do
    CircuitBreaker.start_link(name: :service_cb, failure_threshold: 5, reset_timeout_ms: 30_000)
  end

  def call_service(params) do
    Executor.execute_with_protection(:service_cb,
      fn -> Snakepit.execute("service", params, timeout: 5000) end,
      max_attempts: 3, backoff_ms: [100, 500, 1000], jitter: true
    )
  end

  def health_status do
    %{
      state: CircuitBreaker.state(:service_cb),
      stats: CircuitBreaker.stats(:service_cb)
    }
  end
end
```

## Telemetry Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:snakepit, :circuit_breaker, :opened]` | `%{failure_count: n}` | `%{pool: name}` |
| `[:snakepit, :circuit_breaker, :closed]` | `%{}` | `%{pool: name}` |
| `[:snakepit, :retry, :attempt]` | `%{attempt: n, delay_ms: ms}` | `%{}` |
| `[:snakepit, :retry, :exhausted]` | `%{attempts: n}` | `%{last_error: error}` |
| `[:snakepit, :worker, :crash]` | `%{}` | `%{pool: name, worker_id: id}` |
