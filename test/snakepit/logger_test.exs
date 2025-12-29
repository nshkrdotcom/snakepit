defmodule Snakepit.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Snakepit.Logger.TestHelper

  alias Snakepit.Logger, as: SLog

  setup do
    # Ensure Elixir Logger captures all levels
    previous_level = Application.get_env(:logger, :level)
    Logger.configure(level: :debug)

    # Set up process-level isolation
    setup_log_isolation()

    on_exit(fn ->
      Logger.configure(level: previous_level || :warning)
    end)

    :ok
  end

  describe "default behavior" do
    test "is silent for info level messages" do
      # Clear any process-level override to test default
      SLog.clear_process_level()

      log =
        capture_log(fn ->
          SLog.info("This should not appear")
        end)

      assert log == ""
    end

    test "shows error level messages" do
      # Clear any process-level override to test default
      SLog.clear_process_level()

      log =
        capture_log(fn ->
          SLog.error("This should appear")
        end)

      assert log =~ "This should appear"
    end
  end

  describe "with log_level: :none (process-level)" do
    test "suppresses error messages" do
      log =
        capture_at_level(:none, fn ->
          SLog.error("Nope")
        end)

      assert log == ""
    end
  end

  describe "with_level/2" do
    test "temporarily changes log level" do
      # Default level should filter info
      log1 =
        capture_log(fn ->
          SLog.info("should not appear")
        end)

      assert log1 == ""

      # with_level should enable info
      log2 =
        SLog.with_level(:info, fn ->
          capture_log(fn ->
            SLog.info("should appear")
          end)
        end)

      assert log2 =~ "should appear"

      # After with_level, should be back to default
      log3 =
        capture_log(fn ->
          SLog.info("should not appear again")
        end)

      assert log3 == ""
    end

    test "restores previous level even on exception" do
      SLog.set_process_level(:debug)

      try do
        SLog.with_level(:none, fn ->
          raise "test error"
        end)
      rescue
        RuntimeError -> :ok
      end

      # Should be back to :debug
      assert SLog.get_process_level() == :debug
    end
  end

  describe "set_process_level/1 and get_process_level/0" do
    test "sets and gets process-level log level" do
      SLog.set_process_level(:debug)
      assert SLog.get_process_level() == :debug

      SLog.set_process_level(:warning)
      assert SLog.get_process_level() == :warning
    end

    test "clear_process_level reverts to global default" do
      SLog.set_process_level(:debug)
      SLog.clear_process_level()

      # Should return the global default (usually :error)
      level = SLog.get_process_level()
      assert level == Application.get_env(:snakepit, :log_level, :error)
    end
  end

  describe "categories" do
    setup do
      # Categories still use global config - that's acceptable
      # since they don't typically cause race conditions
      original_categories = Application.get_env(:snakepit, :log_categories)
      Application.put_env(:snakepit, :log_categories, [:grpc])

      on_exit(fn ->
        if original_categories do
          Application.put_env(:snakepit, :log_categories, original_categories)
        else
          Application.delete_env(:snakepit, :log_categories)
        end
      end)

      :ok
    end

    test "filters debug/info by category" do
      grpc_log =
        capture_at_level(:info, fn ->
          SLog.info(:grpc, "gRPC message")
        end)

      pool_log =
        capture_at_level(:info, fn ->
          SLog.info(:pool, "Pool message")
        end)

      assert grpc_log =~ "gRPC message"
      assert pool_log == ""
    end

    test "warnings/errors bypass category filters" do
      log =
        capture_at_level(:warning, fn ->
          SLog.warning(:pool, "Pool warning")
        end)

      assert log =~ "Pool warning"
    end
  end
end
