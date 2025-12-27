defmodule Snakepit.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  setup do
    previous_level = Application.get_env(:logger, :level)
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level || :warning)
    end)

    :ok
  end

  describe "default behavior" do
    test "is silent for info level messages" do
      log =
        capture_log(fn ->
          Snakepit.Logger.info("This should not appear")
        end)

      assert log == ""
    end

    test "shows error level messages" do
      log =
        capture_log(fn ->
          Snakepit.Logger.error("This should appear")
        end)

      assert log =~ "This should appear"
    end
  end

  describe "with log_level: :none" do
    setup do
      Application.put_env(:snakepit, :log_level, :none)

      on_exit(fn ->
        Application.delete_env(:snakepit, :log_level)
      end)

      :ok
    end

    test "suppresses error messages" do
      log =
        capture_log(fn ->
          Snakepit.Logger.error("Nope")
        end)

      assert log == ""
    end
  end

  describe "categories" do
    setup do
      Application.put_env(:snakepit, :log_level, :info)
      Application.put_env(:snakepit, :log_categories, [:grpc])

      on_exit(fn ->
        Application.delete_env(:snakepit, :log_level)
        Application.delete_env(:snakepit, :log_categories)
      end)

      :ok
    end

    test "filters debug/info by category" do
      grpc_log =
        capture_log(fn ->
          Snakepit.Logger.info(:grpc, "gRPC message")
        end)

      pool_log =
        capture_log(fn ->
          Snakepit.Logger.info(:pool, "Pool message")
        end)

      assert grpc_log =~ "gRPC message"
      assert pool_log == ""
    end

    test "warnings/errors bypass category filters" do
      log =
        capture_log(fn ->
          Snakepit.Logger.warning(:pool, "Pool warning")
        end)

      assert log =~ "Pool warning"
    end
  end
end
