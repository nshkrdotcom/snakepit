defmodule Snakepit.Pool.TimeoutTest do
  @moduledoc """
  Tests for Pool timeout propagation and deadline-aware handling.

  These tests verify that:
  1. Pool computes overall timeout once
  2. Deadline is stored in opts for queue-aware remaining time
  3. RPC timeout is derived from remaining budget
  4. Queued requests respect deadline
  """
  use ExUnit.Case, async: true

  alias Snakepit.Defaults
  alias Snakepit.Pool

  describe "get_default_timeout_for_call/3" do
    test "returns explicit timeout from opts when provided" do
      opts = [timeout: 45_000]
      assert Pool.get_default_timeout_for_call(:execute, %{}, opts) == 45_000
    end

    test "returns default_timeout for regular execute when not provided" do
      opts = []
      # Should derive from Defaults.default_timeout() for execute
      expected = Defaults.default_timeout()
      assert Pool.get_default_timeout_for_call(:execute, %{}, opts) == expected
    end

    test "returns stream_timeout for streaming execute when not provided" do
      opts = []
      expected = Defaults.stream_timeout()
      assert Pool.get_default_timeout_for_call(:execute_stream, %{}, opts) == expected
    end

    test "returns queue_timeout for queue operations" do
      opts = []
      expected = Defaults.queue_timeout()
      assert Pool.get_default_timeout_for_call(:queue, %{}, opts) == expected
    end
  end

  describe "derive_rpc_timeout_from_opts/2" do
    test "derives RPC timeout from deadline_ms when present" do
      # Simulate a request that has been waiting in queue for 500ms
      # deadline_ms was set 500ms ago with a 60_000ms total budget
      now = System.monotonic_time(:millisecond)
      # 500ms elapsed of 60_000ms budget
      deadline_ms = now + 59_500
      opts = [deadline_ms: deadline_ms]

      rpc_timeout = Pool.derive_rpc_timeout_from_opts(opts, 60_000)

      # Should be remaining time minus margins
      # remaining ~= 59_500
      # margins = 1000 + 200 = 1200
      # expected ~= 58_300 (approximately, allowing for timing)
      assert rpc_timeout >= 57_000
      assert rpc_timeout <= 59_500
    end

    test "uses full budget when no deadline_ms present" do
      opts = []
      default_timeout = 60_000

      rpc_timeout = Pool.derive_rpc_timeout_from_opts(opts, default_timeout)

      # Should derive from full budget
      expected = Defaults.rpc_timeout(default_timeout)
      assert rpc_timeout == expected
    end

    test "returns minimum timeout when deadline has passed" do
      # Simulate an expired deadline
      now = System.monotonic_time(:millisecond)
      # expired 1 second ago
      deadline_ms = now - 1000
      opts = [deadline_ms: deadline_ms]

      rpc_timeout = Pool.derive_rpc_timeout_from_opts(opts, 60_000)

      # Should return floor (minimum usable timeout)
      assert rpc_timeout >= 1
      assert rpc_timeout <= 1000
    end

    test "handles :infinity gracefully" do
      opts = []
      rpc_timeout = Pool.derive_rpc_timeout_from_opts(opts, :infinity)
      assert rpc_timeout == :infinity
    end
  end

  describe "effective_queue_timeout_ms/2" do
    test "returns queue_timeout when deadline not set" do
      opts = []
      result = Pool.effective_queue_timeout_ms(opts, 10_000)
      assert result == 10_000
    end

    test "returns remaining time when deadline is set and has time left" do
      now = System.monotonic_time(:millisecond)
      # 5 seconds remaining
      deadline_ms = now + 5000
      opts = [deadline_ms: deadline_ms]

      result = Pool.effective_queue_timeout_ms(opts, 10_000)

      # Should return ~5000, not the configured 10_000
      assert result >= 4500
      assert result <= 5500
    end

    test "returns 0 when deadline has passed" do
      now = System.monotonic_time(:millisecond)
      # expired 100ms ago
      deadline_ms = now - 100
      opts = [deadline_ms: deadline_ms]

      result = Pool.effective_queue_timeout_ms(opts, 10_000)

      assert result == 0
    end
  end
end
