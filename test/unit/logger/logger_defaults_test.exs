defmodule Snakepit.LoggerDefaultsTest do
  use ExUnit.Case, async: false

  alias Snakepit.Logger, as: SLog

  setup do
    previous_level = Application.get_env(:snakepit, :log_level)

    on_exit(fn ->
      restore_env(:log_level, previous_level)
    end)

    :ok
  end

  test "defaults to error-only logging" do
    Application.delete_env(:snakepit, :log_level)

    refute SLog.should_log?(:warning)
    refute SLog.should_log?(:info)
    refute SLog.should_log?(:debug)
    assert SLog.should_log?(:error)
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
