# Crash Recovery

Snakepit provides comprehensive fault tolerance through circuit breakers,
health monitoring, retry policies, and execution helpers.

## Circuit Breaker

The circuit breaker prevents cascading failures by temporarily
blocking calls to unhealthy services.

### States

- **Closed**: Normal operation, all calls allowed
- **Open**: Failure threshold exceeded, calls rejected
- **Half-Open**: Testing recovery, limited calls allowed

### Basic Usage

```elixir
# Start a circuit breaker
{:ok, cb} = Snakepit.CircuitBreaker.start_link(
  name: :python_pool,
  failure_threshold: 5,
  reset_timeout_ms: 30_000
)

# Execute through circuit breaker
case Snakepit.CircuitBreaker.call(cb, fn -> risky_operation() end) do
  {:ok, result} -> handle_success(result)
  {:error, :circuit_open} -> handle_circuit_open()
  {:error, reason} -> handle_error(reason)
end
```

### Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:failure_threshold` | 5 | Failures before opening |
| `:reset_timeout_ms` | 30000 | Time before half-open |
| `:half_open_max_calls` | 1 | Calls allowed in half-open |

## Health Monitor

The health monitor tracks crash patterns and determines pool health.

```elixir
# Start health monitor
{:ok, hm} = Snakepit.HealthMonitor.start_link(
  name: :pool_health,
  pool: :default,
  crash_window_ms: 60_000,
  max_crashes: 10
)

# Record crashes
Snakepit.HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})

# Check health
if Snakepit.HealthMonitor.is_healthy?(hm) do
  # Pool is healthy
else
  # Too many crashes, consider action
end

# Get stats
stats = Snakepit.HealthMonitor.stats(hm)
# => %{total_crashes: 5, crashes_in_window: 3, is_healthy: true}
```

## Retry Policy

Configure retry behavior with exponential backoff.

```elixir
policy = Snakepit.RetryPolicy.new(
  max_attempts: 5,
  backoff_ms: [100, 200, 400, 800],
  jitter: true,
  retriable_errors: [:timeout, :unavailable]
)

# Check if should retry
if RetryPolicy.should_retry?(policy, attempt) do
  delay = RetryPolicy.backoff_for_attempt(policy, attempt)
  Process.sleep(delay)
  # retry...
end
```

## Executor

The Executor provides convenient wrappers for common patterns.

### With Retry

```elixir
result = Snakepit.Executor.execute_with_retry(
  fn -> external_api_call() end,
  max_attempts: 3,
  backoff_ms: [100, 200, 400]
)
```

### With Circuit Breaker

```elixir
result = Snakepit.Executor.execute_with_circuit_breaker(
  circuit_breaker,
  fn -> risky_operation() end
)
```

### With Timeout

```elixir
result = Snakepit.Executor.execute_with_timeout(
  fn -> slow_operation() end,
  timeout_ms: 5000
)
```

### Batch Execution

```elixir
results = Snakepit.Executor.execute_batch(
  [fn -> op1() end, fn -> op2() end, fn -> op3() end],
  timeout_ms: 10_000,
  max_concurrency: 4
)
```

## Telemetry Events

All crash barrier components emit telemetry events:

```elixir
:telemetry.attach(
  "my-handler",
  [:snakepit, :circuit_breaker, :opened],
  fn _event, %{failure_count: count}, %{pool: pool}, _config ->
    Logger.warning("Circuit breaker opened for #{pool}: #{count} failures")
  end,
  nil
)
```

Available events:
- `[:snakepit, :circuit_breaker, :opened]`
- `[:snakepit, :circuit_breaker, :closed]`
- `[:snakepit, :circuit_breaker, :half_open]`
- `[:snakepit, :retry, :attempt]`
- `[:snakepit, :retry, :success]`
- `[:snakepit, :retry, :exhausted]`
