defmodule Snakepit.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Snakepit.CircuitBreaker

  describe "start_link/1" do
    test "starts with default options" do
      {:ok, pid} = CircuitBreaker.start_link(name: :test_cb_default)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom thresholds" do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :test_cb_custom,
          failure_threshold: 3,
          reset_timeout_ms: 10_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "state transitions via call/2" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_#{System.unique_integer([:positive])}",
          failure_threshold: 3,
          reset_timeout_ms: 50,
          half_open_max_calls: 1
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      {:ok, cb: pid}
    end

    test "allows calls when closed", %{cb: cb} do
      result = CircuitBreaker.call(cb, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "opens after threshold failures and rejects calls", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      result = CircuitBreaker.call(cb, fn -> {:ok, :success} end)
      assert result == {:error, :circuit_open}
    end

    test "transitions to half-open after timeout and allows call", %{cb: cb} do
      # Open the circuit
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      # Verify it's open
      assert CircuitBreaker.call(cb, fn -> {:ok, :test} end) == {:error, :circuit_open}

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :half_open end,
        timeout: 500,
        interval: 10
      )

      # Should be half-open now - allows one call
      result = CircuitBreaker.call(cb, fn -> {:ok, :half_open_test} end)
      assert result == {:ok, :half_open_test}
    end

    test "closes on success in half-open state", %{cb: cb} do
      # Open then wait for half-open
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :half_open end,
        timeout: 500,
        interval: 10
      )

      # Call succeeds in half-open state, circuit should close
      CircuitBreaker.call(cb, fn -> {:ok, :success} end)

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :closed end,
        timeout: 500,
        interval: 10
      )

      # Now should be closed - multiple calls should work
      assert CircuitBreaker.call(cb, fn -> {:ok, :test1} end) == {:ok, :test1}
      assert CircuitBreaker.call(cb, fn -> {:ok, :test2} end) == {:ok, :test2}
    end

    test "re-opens on failure in half-open state", %{cb: cb} do
      # Open then wait for half-open
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :half_open end,
        timeout: 500,
        interval: 10
      )

      # Fail in half-open state
      CircuitBreaker.call(cb, fn -> {:error, :fail} end)

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :open end,
        timeout: 500,
        interval: 10
      )

      # Should be open again
      result = CircuitBreaker.call(cb, fn -> {:ok, :should_not_run} end)
      assert result == {:error, :circuit_open}
    end
  end

  describe "state/1 and allow_call?/1" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_state_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 50,
          half_open_max_calls: 1
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      {:ok, cb: pid}
    end

    test "starts closed and allows calls", %{cb: cb} do
      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.allow_call?(cb)
    end

    test "reports open and rejects calls after threshold failures", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      assert CircuitBreaker.state(cb) == :open
      refute CircuitBreaker.allow_call?(cb)
    end

    test "transitions to half-open after timeout", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      TestHelpers.assert_eventually(
        fn -> CircuitBreaker.state(cb) == :half_open end,
        timeout: 500,
        interval: 10
      )

      assert CircuitBreaker.allow_call?(cb)
    end
  end

  describe "stats/1 and reset/1" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_stats_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 50
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      {:ok, cb: pid}
    end

    test "reports counters in stats", %{cb: cb} do
      CircuitBreaker.record_success(cb)
      CircuitBreaker.record_failure(cb)

      stats = CircuitBreaker.stats(cb)
      assert stats.success_count >= 1
      assert stats.failure_count >= 1
      assert stats.failure_threshold == 2
    end

    test "resets open circuit to closed state", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      assert CircuitBreaker.state(cb) == :open

      CircuitBreaker.reset(cb)
      assert CircuitBreaker.state(cb) == :closed
    end
  end

  describe "call/2" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_call_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 50
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      {:ok, cb: pid}
    end

    test "executes function when closed", %{cb: cb} do
      result = CircuitBreaker.call(cb, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "rejects function when open", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      result = CircuitBreaker.call(cb, fn -> {:ok, :success} end)
      assert result == {:error, :circuit_open}
    end

    test "propagates exceptions", %{cb: cb} do
      assert_raise RuntimeError, "test error", fn ->
        CircuitBreaker.call(cb, fn -> raise "test error" end)
      end
    end
  end
end
