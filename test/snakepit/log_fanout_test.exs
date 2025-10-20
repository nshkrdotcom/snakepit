defmodule Snakepit.LogFanoutTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  require Logger

  alias Snakepit.LogFanout

  setup do
    original_flag = Application.get_env(:snakepit, :dev_logfanout?, false)
    original_path = Application.get_env(:snakepit, :dev_log_path)
    original_level = Application.get_env(:snakepit, :log_level, :info)
    original_logger_level = Logger.level()

    Logger.configure(level: :info)

    on_exit(fn ->
      Application.put_env(:snakepit, :dev_logfanout?, original_flag)

      if original_path do
        Application.put_env(:snakepit, :dev_log_path, original_path)
      else
        Application.delete_env(:snakepit, :dev_log_path)
      end

      Application.put_env(:snakepit, :log_level, original_level)
      Logger.configure(level: original_logger_level)
    end)

    :ok
  end

  test "falls back to logger when fanout disabled" do
    Application.put_env(:snakepit, :dev_logfanout?, false)
    Application.put_env(:snakepit, :log_level, :info)

    log =
      capture_log(fn ->
        LogFanout.handle_log("hello world", worker_id: "worker-1")
      end)

    assert log =~ "hello world"
  end

  test "appends metadata to configured log file when enabled" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "snakepit_log_fanout_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp_dir)
    log_path = Path.join(tmp_dir, "python-dev.log")

    Application.put_env(:snakepit, :dev_logfanout?, true)
    Application.put_env(:snakepit, :dev_log_path, log_path)
    Application.put_env(:snakepit, :log_level, :info)

    capture_log(fn ->
      LogFanout.handle_log("connected", worker_id: "worker-1", pool: :default)
    end)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    contents = File.read!(log_path)
    assert contents =~ "[snakepit]"
    assert contents =~ "worker_id=worker-1"
    assert contents =~ "pool=default"
    assert contents =~ "connected"
  end
end
