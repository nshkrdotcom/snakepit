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

  describe "state transitions" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_#{System.unique_integer([:positive])}",
          failure_threshold: 3,
          reset_timeout_ms: 100,
          half_open_max_calls: 1
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, cb: pid}
    end

    test "starts in closed state", %{cb: cb} do
      assert CircuitBreaker.state(cb) == :closed
    end

    test "stays closed on success", %{cb: cb} do
      CircuitBreaker.record_success(cb)
      assert CircuitBreaker.state(cb) == :closed
    end

    test "opens after threshold failures", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      assert CircuitBreaker.state(cb) == :open
    end

    test "transitions to half-open after timeout", %{cb: cb} do
      # Open the circuit
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      assert CircuitBreaker.state(cb) == :open

      # Wait for reset timeout
      Process.sleep(150)

      assert CircuitBreaker.state(cb) == :half_open
    end

    test "closes on success in half-open state", %{cb: cb} do
      # Open then wait for half-open
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      Process.sleep(150)

      assert CircuitBreaker.state(cb) == :half_open

      CircuitBreaker.record_success(cb)
      assert CircuitBreaker.state(cb) == :closed
    end

    test "re-opens on failure in half-open state", %{cb: cb} do
      # Open then wait for half-open
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      Process.sleep(150)

      assert CircuitBreaker.state(cb) == :half_open

      CircuitBreaker.record_failure(cb)
      assert CircuitBreaker.state(cb) == :open
    end
  end

  describe "allow_call?/1" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_allow_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 100
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, cb: pid}
    end

    test "allows calls when closed", %{cb: cb} do
      assert CircuitBreaker.allow_call?(cb) == true
    end

    test "rejects calls when open", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)

      assert CircuitBreaker.state(cb) == :open
      assert CircuitBreaker.allow_call?(cb) == false
    end

    test "allows limited calls in half-open", %{cb: cb} do
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      Process.sleep(150)

      assert CircuitBreaker.state(cb) == :half_open
      assert CircuitBreaker.allow_call?(cb) == true
    end
  end

  describe "call/2" do
    setup do
      {:ok, pid} =
        CircuitBreaker.start_link(
          name: :"cb_call_#{System.unique_integer([:positive])}",
          failure_threshold: 2,
          reset_timeout_ms: 100
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
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

    test "records success on ok result", %{cb: cb} do
      CircuitBreaker.call(cb, fn -> {:ok, :success} end)

      stats = CircuitBreaker.stats(cb)
      assert stats.success_count > 0
    end

    test "records failure on error result", %{cb: cb} do
      CircuitBreaker.call(cb, fn -> {:error, :failed} end)

      stats = CircuitBreaker.stats(cb)
      assert stats.failure_count > 0
    end

    test "records failure on exception", %{cb: cb} do
      catch_error(CircuitBreaker.call(cb, fn -> raise "test error" end))

      stats = CircuitBreaker.stats(cb)
      assert stats.failure_count > 0
    end
  end

  describe "stats/1" do
    test "returns stats map" do
      {:ok, cb} =
        CircuitBreaker.start_link(name: :"cb_stats_#{System.unique_integer([:positive])}")

      stats = CircuitBreaker.stats(cb)

      assert is_map(stats)
      assert Map.has_key?(stats, :state)
      assert Map.has_key?(stats, :failure_count)
      assert Map.has_key?(stats, :success_count)

      GenServer.stop(cb)
    end
  end

  describe "reset/1" do
    test "resets to closed state" do
      {:ok, cb} =
        CircuitBreaker.start_link(
          name: :"cb_reset_#{System.unique_integer([:positive])}",
          failure_threshold: 2
        )

      # Open the circuit
      CircuitBreaker.record_failure(cb)
      CircuitBreaker.record_failure(cb)
      assert CircuitBreaker.state(cb) == :open

      # Reset
      CircuitBreaker.reset(cb)
      assert CircuitBreaker.state(cb) == :closed

      GenServer.stop(cb)
    end
  end
end
