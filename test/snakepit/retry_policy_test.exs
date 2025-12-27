defmodule Snakepit.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Snakepit.RetryPolicy

  describe "new/1" do
    test "creates policy with defaults" do
      policy = RetryPolicy.new([])

      assert policy.max_attempts > 0
      assert is_list(policy.backoff_ms)
    end

    test "creates policy with custom options" do
      policy =
        RetryPolicy.new(
          max_attempts: 5,
          backoff_ms: [100, 200, 400],
          jitter: true
        )

      assert policy.max_attempts == 5
      assert policy.backoff_ms == [100, 200, 400]
      assert policy.jitter == true
    end
  end

  describe "should_retry?/2" do
    test "returns true when attempts remain" do
      policy = RetryPolicy.new(max_attempts: 3)

      assert RetryPolicy.should_retry?(policy, 1) == true
      assert RetryPolicy.should_retry?(policy, 2) == true
    end

    test "returns false when attempts exhausted" do
      policy = RetryPolicy.new(max_attempts: 3)

      assert RetryPolicy.should_retry?(policy, 3) == false
      assert RetryPolicy.should_retry?(policy, 4) == false
    end
  end

  describe "retry_for_error?/2" do
    test "retries retriable errors by default" do
      policy = RetryPolicy.new([])

      assert RetryPolicy.retry_for_error?(policy, {:error, :timeout}) == true
      assert RetryPolicy.retry_for_error?(policy, {:error, :unavailable}) == true
    end

    test "does not retry non-retriable errors" do
      policy = RetryPolicy.new([])

      assert RetryPolicy.retry_for_error?(policy, {:error, :invalid_input}) == false
    end

    test "respects custom retriable errors" do
      policy = RetryPolicy.new(retriable_errors: [:custom_error])

      assert RetryPolicy.retry_for_error?(policy, {:error, :custom_error}) == true
      assert RetryPolicy.retry_for_error?(policy, {:error, :timeout}) == false
    end
  end

  describe "backoff_for_attempt/2" do
    test "returns backoff from list" do
      policy = RetryPolicy.new(backoff_ms: [100, 200, 400])

      assert RetryPolicy.backoff_for_attempt(policy, 1) == 100
      assert RetryPolicy.backoff_for_attempt(policy, 2) == 200
      assert RetryPolicy.backoff_for_attempt(policy, 3) == 400
    end

    test "uses last value when past list end" do
      policy = RetryPolicy.new(backoff_ms: [100, 200])

      assert RetryPolicy.backoff_for_attempt(policy, 3) == 200
      assert RetryPolicy.backoff_for_attempt(policy, 10) == 200
    end

    test "applies jitter when enabled" do
      policy = RetryPolicy.new(backoff_ms: [1000], jitter: true, jitter_factor: 0.5)

      # With jitter, values should vary
      values = for _ <- 1..10, do: RetryPolicy.backoff_for_attempt(policy, 1)

      # Not all values should be exactly the same
      assert length(Enum.uniq(values)) > 1
    end

    test "caps at max_backoff_ms" do
      policy = RetryPolicy.new(backoff_ms: [100, 200, 10_000], max_backoff_ms: 500)

      assert RetryPolicy.backoff_for_attempt(policy, 3) == 500
    end
  end

  describe "exponential backoff" do
    test "calculates exponential backoff" do
      policy = RetryPolicy.new(base_backoff_ms: 100, backoff_multiplier: 2.0)

      assert RetryPolicy.exponential_backoff(policy, 1) == 100
      assert RetryPolicy.exponential_backoff(policy, 2) == 200
      assert RetryPolicy.exponential_backoff(policy, 3) == 400
    end
  end

  describe "with_circuit_breaker/2" do
    test "adds circuit breaker reference" do
      policy = RetryPolicy.new([])

      cb_ref = make_ref()
      new_policy = RetryPolicy.with_circuit_breaker(policy, cb_ref)

      assert new_policy.circuit_breaker == cb_ref
    end
  end
end
