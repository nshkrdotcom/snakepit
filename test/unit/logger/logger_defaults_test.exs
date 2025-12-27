defmodule Snakepit.LoggerDefaultsTest do
  use ExUnit.Case, async: false

  alias Snakepit.Logger, as: SLog

  setup do
    previous_level = Application.get_env(:snakepit, :log_level)
    previous_library_mode = Application.get_env(:snakepit, :library_mode)

    on_exit(fn ->
      restore_env(:log_level, previous_level)
      restore_env(:library_mode, previous_library_mode)
    end)

    :ok
  end

  test "defaults to warning and still logs errors" do
    Application.delete_env(:snakepit, :log_level)
    Application.put_env(:snakepit, :library_mode, true)

    assert SLog.should_log?(:warning)
    refute SLog.should_log?(:info)
    assert SLog.should_log?(:error)
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
