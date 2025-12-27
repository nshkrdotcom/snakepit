#!/usr/bin/env elixir

# Crash Recovery Example
# Demonstrates fault tolerance patterns including circuit breakers,
# health monitoring, retry policies, and execution helpers.
#
# Usage: mix run examples/crash_recovery.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule CrashRecoveryExample do
  @moduledoc """
  Demonstrates Snakepit's crash barrier and fault tolerance features.
  """

  alias Snakepit.{CircuitBreaker, HealthMonitor, RetryPolicy, Executor}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Crash Recovery and Fault Tolerance")
    IO.puts(String.duplicate("=", 60) <> "\n")

    demo_circuit_breaker()
    demo_health_monitor()
    demo_retry_policy()
    demo_executor()
    demo_combined_protection()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Crash Recovery Demo Complete!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  defp demo_circuit_breaker do
    IO.puts("1. Circuit Breaker Pattern")
    IO.puts(String.duplicate("-", 40))

    # Start a circuit breaker
    {:ok, cb} =
      CircuitBreaker.start_link(
        name: :"demo_cb_#{System.unique_integer([:positive])}",
        failure_threshold: 3,
        reset_timeout_ms: 5_000,
        half_open_max_calls: 1
      )

    IO.puts("   Circuit breaker started (threshold: 3 failures)")
    IO.puts("   Initial state: #{CircuitBreaker.state(cb)}")

    # Successful calls
    IO.puts("\n   Executing successful operations...")

    for i <- 1..2 do
      result = CircuitBreaker.call(cb, fn -> {:ok, "success #{i}"} end)
      IO.puts("   Call #{i}: #{inspect(result)}")
    end

    IO.puts("   State after successes: #{CircuitBreaker.state(cb)}")

    # Failing calls to trigger circuit open
    IO.puts("\n   Simulating failures to open circuit...")

    for i <- 1..4 do
      result = CircuitBreaker.call(cb, fn -> {:error, :simulated_failure} end)

      case result do
        {:error, :circuit_open} ->
          IO.puts("   Failure #{i}: Circuit is OPEN - call rejected!")

        {:error, reason} ->
          IO.puts("   Failure #{i}: #{inspect(reason)}")
      end
    end

    stats = CircuitBreaker.stats(cb)
    IO.puts("\n   Final Stats:")
    IO.puts("   - State: #{stats.state}")
    IO.puts("   - Failure count: #{stats.failure_count}")
    IO.puts("   - Success count: #{stats.success_count}")
    IO.puts("   - Half-open calls: #{stats.half_open_calls}")

    GenServer.stop(cb)
    IO.puts("")
  end

  defp demo_health_monitor do
    IO.puts("2. Health Monitor")
    IO.puts(String.duplicate("-", 40))

    # Start health monitor
    {:ok, hm} =
      HealthMonitor.start_link(
        name: :"demo_hm_#{System.unique_integer([:positive])}",
        pool: :demo_pool,
        max_crashes: 5,
        crash_window_ms: 60_000,
        check_interval_ms: 10_000
      )

    IO.puts("   Health monitor started (max crashes: 5 per minute)")

    IO.puts(
      "   Initial health: #{if HealthMonitor.healthy?(hm), do: "healthy", else: "unhealthy"}"
    )

    # Record some crashes
    IO.puts("\n   Recording worker crashes...")

    HealthMonitor.record_crash(hm, "worker_1", %{reason: :timeout})
    IO.puts("   Crash 1: worker_1 (timeout)")

    HealthMonitor.record_crash(hm, "worker_2", %{reason: :oom})
    IO.puts("   Crash 2: worker_2 (oom)")

    HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})
    IO.puts("   Crash 3: worker_1 (segfault)")

    # Check health
    stats = HealthMonitor.stats(hm)
    IO.puts("\n   Health Stats:")
    IO.puts("   - Pool: #{stats.pool}")
    IO.puts("   - Total crashes: #{stats.total_crashes}")
    IO.puts("   - Crashes in window: #{stats.crashes_in_window}")
    IO.puts("   - Workers affected: #{stats.workers_with_crashes}")
    IO.puts("   - Is healthy: #{stats.is_healthy}")

    # Check individual worker health
    worker_health = HealthMonitor.worker_health(hm, "worker_1")
    IO.puts("\n   Worker 1 Health:")
    IO.puts("   - Healthy: #{worker_health.healthy}")
    IO.puts("   - Crash count: #{worker_health.crash_count}")

    # Add more crashes to make unhealthy
    IO.puts("\n   Adding more crashes to trigger unhealthy state...")

    for i <- 4..6 do
      HealthMonitor.record_crash(hm, "worker_#{i}", %{reason: :error})
      IO.puts("   Crash #{i}: worker_#{i}")
    end

    IO.puts(
      "   Health status: #{if HealthMonitor.healthy?(hm), do: "healthy", else: "UNHEALTHY"}"
    )

    GenServer.stop(hm)
    IO.puts("")
  end

  defp demo_retry_policy do
    IO.puts("3. Retry Policy")
    IO.puts(String.duplicate("-", 40))

    # Create a retry policy
    policy =
      RetryPolicy.new(
        max_attempts: 4,
        backoff_ms: [100, 200, 400, 800],
        jitter: true,
        retriable_errors: [:timeout, :unavailable, :service_unavailable]
      )

    IO.puts("   Retry policy created:")
    IO.puts("   - Max attempts: #{policy.max_attempts}")
    IO.puts("   - Backoff: #{inspect(policy.backoff_ms)} ms")
    IO.puts("   - Jitter: #{policy.jitter}")
    IO.puts("   - Retriable errors: #{inspect(policy.retriable_errors)}")

    # Check retry decisions
    IO.puts("\n   Retry decisions:")

    for attempt <- 1..5 do
      should_retry = RetryPolicy.should_retry?(policy, attempt)
      backoff = RetryPolicy.backoff_for_attempt(policy, attempt)
      IO.puts("   Attempt #{attempt}: should_retry=#{should_retry}, backoff=#{backoff}ms")
    end

    # Check error retriability
    IO.puts("\n   Error retriability:")
    errors = [:timeout, :unavailable, :connection_refused, {:error, :timeout}]

    for error <- errors do
      retriable = RetryPolicy.retry_for_error?(policy, error)
      IO.puts("   #{inspect(error)}: retriable=#{retriable}")
    end

    IO.puts("")
  end

  defp demo_executor do
    IO.puts("4. Executor Patterns")
    IO.puts(String.duplicate("-", 40))

    # Simple execution
    IO.puts("   a) Simple execution:")
    result = Executor.execute(fn -> {:ok, "direct result"} end)
    IO.puts("      Result: #{inspect(result)}")

    # Execution with timeout
    IO.puts("\n   b) Execution with timeout:")

    fast_result =
      Executor.execute_with_timeout(
        fn -> {:ok, "fast operation"} end,
        timeout_ms: 1000
      )

    IO.puts("      Fast operation: #{inspect(fast_result)}")

    slow_result =
      Executor.execute_with_timeout(
        fn ->
          Process.sleep(100)
          {:ok, "completed"}
        end,
        timeout_ms: 50
      )

    IO.puts("      Slow operation (50ms timeout): #{inspect(slow_result)}")

    # Execution with retry
    IO.puts("\n   c) Execution with retry:")

    # Counter to track attempts
    counter = :counters.new(1, [:atomics])

    retry_result =
      Executor.execute_with_retry(
        fn ->
          attempt = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, attempt)

          if attempt < 3 do
            {:error, :timeout}
          else
            {:ok, "succeeded on attempt #{attempt}"}
          end
        end,
        max_attempts: 5,
        backoff_ms: [10, 20, 40]
      )

    IO.puts("      Result: #{inspect(retry_result)}")
    IO.puts("      Total attempts: #{:counters.get(counter, 1)}")

    # Batch execution
    IO.puts("\n   d) Batch execution:")

    operations = [
      fn -> {:ok, "op1"} end,
      fn -> {:ok, "op2"} end,
      fn -> {:ok, "op3"} end,
      fn -> {:error, :failed} end
    ]

    batch_results =
      Executor.execute_batch(operations,
        timeout_ms: 5000,
        max_concurrency: 2
      )

    IO.puts("      Results: #{inspect(batch_results)}")

    IO.puts("")
  end

  defp demo_combined_protection do
    IO.puts("5. Combined Protection (Retry + Circuit Breaker)")
    IO.puts(String.duplicate("-", 40))

    # Start a circuit breaker
    {:ok, cb} =
      CircuitBreaker.start_link(
        name: :"combined_cb_#{System.unique_integer([:positive])}",
        failure_threshold: 3,
        reset_timeout_ms: 1_000
      )

    IO.puts("   Starting protected execution...")
    IO.puts("   (Retry policy + Circuit Breaker)")

    # Counter for attempts
    counter = :counters.new(1, [:atomics])

    # Execute with protection
    result =
      Executor.execute_with_protection(
        cb,
        fn ->
          attempt = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, attempt)

          if attempt < 2 do
            {:error, :timeout}
          else
            {:ok, "protected success on attempt #{attempt}"}
          end
        end,
        max_attempts: 3,
        backoff_ms: [10, 20]
      )

    IO.puts("   Result: #{inspect(result)}")
    IO.puts("   Attempts made: #{:counters.get(counter, 1)}")
    IO.puts("   Circuit state: #{CircuitBreaker.state(cb)}")

    GenServer.stop(cb)
    IO.puts("")
  end
end

# Run the example
CrashRecoveryExample.run()
