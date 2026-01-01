defmodule Snakepit.DefaultsTimeoutTest do
  @moduledoc """
  Tests for the timeout profile architecture in Snakepit.Defaults.

  This implements TDD for the single-budget, derived deadlines, profile-based defaults
  system proposed for timeout management.
  """
  use ExUnit.Case, async: true

  alias Snakepit.Defaults

  describe "timeout_profiles/0" do
    test "returns all defined timeout profiles" do
      profiles = Defaults.timeout_profiles()

      assert is_map(profiles)
      assert Map.has_key?(profiles, :balanced)
      assert Map.has_key?(profiles, :production)
      assert Map.has_key?(profiles, :production_strict)
      assert Map.has_key?(profiles, :development)
      assert Map.has_key?(profiles, :ml_inference)
      assert Map.has_key?(profiles, :batch)
    end
  end

  describe "timeout_profile/0" do
    test "returns configured timeout profile" do
      # Default should be :balanced
      assert Defaults.timeout_profile() == :balanced
    end

    test "returns configured profile when set" do
      original = Application.get_env(:snakepit, :timeout_profile)

      try do
        Application.put_env(:snakepit, :timeout_profile, :production)
        assert Defaults.timeout_profile() == :production

        Application.put_env(:snakepit, :timeout_profile, :development)
        assert Defaults.timeout_profile() == :development
      after
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end
    end
  end

  describe "profile values - :balanced" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :balanced)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 300_000 (5 minutes)" do
      assert Defaults.default_timeout() == 300_000
    end

    test "stream_timeout returns 900_000 (15 minutes)" do
      assert Defaults.stream_timeout() == 900_000
    end

    test "queue_timeout returns 10_000 (10 seconds)" do
      assert Defaults.queue_timeout() == 10_000
    end
  end

  describe "profile values - :production" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :production)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 300_000 (5 minutes)" do
      assert Defaults.default_timeout() == 300_000
    end

    test "stream_timeout returns 900_000 (15 minutes)" do
      assert Defaults.stream_timeout() == 900_000
    end

    test "queue_timeout returns 10_000 (10 seconds)" do
      assert Defaults.queue_timeout() == 10_000
    end
  end

  describe "profile values - :production_strict" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :production_strict)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 60_000 (60 seconds)" do
      assert Defaults.default_timeout() == 60_000
    end

    test "stream_timeout returns 300_000 (5 minutes)" do
      assert Defaults.stream_timeout() == 300_000
    end

    test "queue_timeout returns 5_000 (5 seconds)" do
      assert Defaults.queue_timeout() == 5_000
    end
  end

  describe "profile values - :development" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :development)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 900_000 (15 minutes)" do
      assert Defaults.default_timeout() == 900_000
    end

    test "stream_timeout returns 3_600_000 (60 minutes)" do
      assert Defaults.stream_timeout() == 3_600_000
    end

    test "queue_timeout returns 60_000 (60 seconds)" do
      assert Defaults.queue_timeout() == 60_000
    end
  end

  describe "profile values - :ml_inference" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :ml_inference)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 900_000 (15 minutes)" do
      assert Defaults.default_timeout() == 900_000
    end

    test "stream_timeout returns 3_600_000 (60 minutes)" do
      assert Defaults.stream_timeout() == 3_600_000
    end

    test "queue_timeout returns 60_000 (60 seconds)" do
      assert Defaults.queue_timeout() == 60_000
    end
  end

  describe "profile values - :batch" do
    setup do
      original = Application.get_env(:snakepit, :timeout_profile)
      Application.put_env(:snakepit, :timeout_profile, :batch)

      on_exit(fn ->
        if original,
          do: Application.put_env(:snakepit, :timeout_profile, original),
          else: Application.delete_env(:snakepit, :timeout_profile)
      end)

      :ok
    end

    test "default_timeout returns 3_600_000 (60 minutes)" do
      assert Defaults.default_timeout() == 3_600_000
    end

    test "stream_timeout returns :infinity" do
      assert Defaults.stream_timeout() == :infinity
    end

    test "queue_timeout returns 300_000 (5 minutes)" do
      assert Defaults.queue_timeout() == 300_000
    end
  end

  describe "margin functions" do
    test "worker_call_margin_ms returns 1000 by default" do
      assert Defaults.worker_call_margin_ms() == 1000
    end

    test "pool_reply_margin_ms returns 200 by default" do
      assert Defaults.pool_reply_margin_ms() == 200
    end

    test "worker_call_margin_ms honors explicit config" do
      original = Application.get_env(:snakepit, :worker_call_margin_ms)

      try do
        Application.put_env(:snakepit, :worker_call_margin_ms, 2000)
        assert Defaults.worker_call_margin_ms() == 2000
      after
        if original,
          do: Application.put_env(:snakepit, :worker_call_margin_ms, original),
          else: Application.delete_env(:snakepit, :worker_call_margin_ms)
      end
    end

    test "pool_reply_margin_ms honors explicit config" do
      original = Application.get_env(:snakepit, :pool_reply_margin_ms)

      try do
        Application.put_env(:snakepit, :pool_reply_margin_ms, 500)
        assert Defaults.pool_reply_margin_ms() == 500
      after
        if original,
          do: Application.put_env(:snakepit, :pool_reply_margin_ms, original),
          else: Application.delete_env(:snakepit, :pool_reply_margin_ms)
      end
    end
  end

  describe "rpc_timeout/1" do
    test "derives inner timeout from total budget minus margins" do
      # Formula: rpc_timeout = total_timeout - worker_call_margin_ms (1000) - pool_reply_margin_ms (200)
      # For 60_000ms total: 60_000 - 1000 - 200 = 58_800
      assert Defaults.rpc_timeout(60_000) == 58_800
    end

    test "returns minimum timeout when total is too small" do
      # Even with small total, should return at least 1ms (or similar floor)
      result = Defaults.rpc_timeout(500)
      # With margins of 1200ms total, 500 - 1200 = -700, floored to minimum
      assert result >= 1
    end

    test "handles :infinity" do
      assert Defaults.rpc_timeout(:infinity) == :infinity
    end

    test "uses configurable margins" do
      original_worker = Application.get_env(:snakepit, :worker_call_margin_ms)
      original_pool = Application.get_env(:snakepit, :pool_reply_margin_ms)

      try do
        Application.put_env(:snakepit, :worker_call_margin_ms, 500)
        Application.put_env(:snakepit, :pool_reply_margin_ms, 100)
        # 60_000 - 500 - 100 = 59_400
        assert Defaults.rpc_timeout(60_000) == 59_400
      after
        if original_worker,
          do: Application.put_env(:snakepit, :worker_call_margin_ms, original_worker),
          else: Application.delete_env(:snakepit, :worker_call_margin_ms)

        if original_pool,
          do: Application.put_env(:snakepit, :pool_reply_margin_ms, original_pool),
          else: Application.delete_env(:snakepit, :pool_reply_margin_ms)
      end
    end
  end

  describe "legacy getters derive from new budgets when not explicitly configured" do
    setup do
      # Clear any explicit configuration to test derivation
      original_profile = Application.get_env(:snakepit, :timeout_profile)
      original_pool_request = Application.get_env(:snakepit, :pool_request_timeout)
      original_pool_streaming = Application.get_env(:snakepit, :pool_streaming_timeout)
      original_pool_queue = Application.get_env(:snakepit, :pool_queue_timeout)
      original_grpc_command = Application.get_env(:snakepit, :grpc_command_timeout)
      original_grpc_worker_execute = Application.get_env(:snakepit, :grpc_worker_execute_timeout)
      original_checkout = Application.get_env(:snakepit, :checkout_timeout)
      original_default_command = Application.get_env(:snakepit, :default_command_timeout)

      Application.delete_env(:snakepit, :pool_request_timeout)
      Application.delete_env(:snakepit, :pool_streaming_timeout)
      Application.delete_env(:snakepit, :pool_queue_timeout)
      Application.delete_env(:snakepit, :grpc_command_timeout)
      Application.delete_env(:snakepit, :grpc_worker_execute_timeout)
      Application.delete_env(:snakepit, :checkout_timeout)
      Application.delete_env(:snakepit, :default_command_timeout)
      Application.put_env(:snakepit, :timeout_profile, :balanced)

      on_exit(fn ->
        # Restore all original values
        if original_profile,
          do: Application.put_env(:snakepit, :timeout_profile, original_profile),
          else: Application.delete_env(:snakepit, :timeout_profile)

        if original_pool_request,
          do: Application.put_env(:snakepit, :pool_request_timeout, original_pool_request),
          else: Application.delete_env(:snakepit, :pool_request_timeout)

        if original_pool_streaming,
          do: Application.put_env(:snakepit, :pool_streaming_timeout, original_pool_streaming),
          else: Application.delete_env(:snakepit, :pool_streaming_timeout)

        if original_pool_queue,
          do: Application.put_env(:snakepit, :pool_queue_timeout, original_pool_queue),
          else: Application.delete_env(:snakepit, :pool_queue_timeout)

        if original_grpc_command,
          do: Application.put_env(:snakepit, :grpc_command_timeout, original_grpc_command),
          else: Application.delete_env(:snakepit, :grpc_command_timeout)

        if original_grpc_worker_execute,
          do:
            Application.put_env(
              :snakepit,
              :grpc_worker_execute_timeout,
              original_grpc_worker_execute
            ),
          else: Application.delete_env(:snakepit, :grpc_worker_execute_timeout)

        if original_checkout,
          do: Application.put_env(:snakepit, :checkout_timeout, original_checkout),
          else: Application.delete_env(:snakepit, :checkout_timeout)

        if original_default_command,
          do: Application.put_env(:snakepit, :default_command_timeout, original_default_command),
          else: Application.delete_env(:snakepit, :default_command_timeout)
      end)

      :ok
    end

    test "pool_request_timeout derives from default_timeout" do
      # When not configured, should derive from default_timeout()
      assert Defaults.pool_request_timeout() == Defaults.default_timeout()
    end

    test "pool_streaming_timeout derives from stream_timeout" do
      assert Defaults.pool_streaming_timeout() == Defaults.stream_timeout()
    end

    test "pool_queue_timeout derives from queue_timeout" do
      assert Defaults.pool_queue_timeout() == Defaults.queue_timeout()
    end

    test "grpc_command_timeout derives from rpc_timeout of default_timeout" do
      expected = Defaults.rpc_timeout(Defaults.default_timeout())
      assert Defaults.grpc_command_timeout() == expected
    end

    test "grpc_worker_execute_timeout derives from rpc_timeout of default_timeout" do
      expected = Defaults.rpc_timeout(Defaults.default_timeout())
      assert Defaults.grpc_worker_execute_timeout() == expected
    end

    test "checkout_timeout derives from queue_timeout" do
      assert Defaults.checkout_timeout() == Defaults.queue_timeout()
    end

    test "default_command_timeout derives from rpc_timeout of default_timeout" do
      expected = Defaults.rpc_timeout(Defaults.default_timeout())
      assert Defaults.default_command_timeout() == expected
    end
  end

  describe "legacy getters honor explicit config when set" do
    test "pool_request_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :pool_request_timeout)

      try do
        Application.put_env(:snakepit, :pool_request_timeout, 120_000)
        assert Defaults.pool_request_timeout() == 120_000
      after
        if original,
          do: Application.put_env(:snakepit, :pool_request_timeout, original),
          else: Application.delete_env(:snakepit, :pool_request_timeout)
      end
    end

    test "pool_streaming_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :pool_streaming_timeout)

      try do
        Application.put_env(:snakepit, :pool_streaming_timeout, 600_000)
        assert Defaults.pool_streaming_timeout() == 600_000
      after
        if original,
          do: Application.put_env(:snakepit, :pool_streaming_timeout, original),
          else: Application.delete_env(:snakepit, :pool_streaming_timeout)
      end
    end

    test "pool_queue_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :pool_queue_timeout)

      try do
        Application.put_env(:snakepit, :pool_queue_timeout, 15_000)
        assert Defaults.pool_queue_timeout() == 15_000
      after
        if original,
          do: Application.put_env(:snakepit, :pool_queue_timeout, original),
          else: Application.delete_env(:snakepit, :pool_queue_timeout)
      end
    end

    test "grpc_command_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :grpc_command_timeout)

      try do
        Application.put_env(:snakepit, :grpc_command_timeout, 45_000)
        assert Defaults.grpc_command_timeout() == 45_000
      after
        if original,
          do: Application.put_env(:snakepit, :grpc_command_timeout, original),
          else: Application.delete_env(:snakepit, :grpc_command_timeout)
      end
    end

    test "grpc_worker_execute_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :grpc_worker_execute_timeout)

      try do
        Application.put_env(:snakepit, :grpc_worker_execute_timeout, 90_000)
        assert Defaults.grpc_worker_execute_timeout() == 90_000
      after
        if original,
          do: Application.put_env(:snakepit, :grpc_worker_execute_timeout, original),
          else: Application.delete_env(:snakepit, :grpc_worker_execute_timeout)
      end
    end

    test "checkout_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :checkout_timeout)

      try do
        Application.put_env(:snakepit, :checkout_timeout, 8_000)
        assert Defaults.checkout_timeout() == 8_000
      after
        if original,
          do: Application.put_env(:snakepit, :checkout_timeout, original),
          else: Application.delete_env(:snakepit, :checkout_timeout)
      end
    end

    test "default_command_timeout uses explicit config" do
      original = Application.get_env(:snakepit, :default_command_timeout)

      try do
        Application.put_env(:snakepit, :default_command_timeout, 50_000)
        assert Defaults.default_command_timeout() == 50_000
      after
        if original,
          do: Application.put_env(:snakepit, :default_command_timeout, original),
          else: Application.delete_env(:snakepit, :default_command_timeout)
      end
    end
  end
end
