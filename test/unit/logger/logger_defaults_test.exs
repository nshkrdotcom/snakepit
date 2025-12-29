defmodule Snakepit.LoggerDefaultsTest do
  use ExUnit.Case, async: true

  import Snakepit.Logger.TestHelper

  alias Snakepit.Logger, as: SLog

  setup do
    # Set up process-level isolation
    setup_log_isolation()
    :ok
  end

  test "defaults to error-only logging when process level not set" do
    # Clear any process-level override to test global default behavior
    SLog.clear_process_level()

    # The global default is :error
    refute SLog.should_log?(:warning)
    refute SLog.should_log?(:info)
    refute SLog.should_log?(:debug)
    assert SLog.should_log?(:error)
  end

  test "process-level overrides can enable more logging" do
    SLog.set_process_level(:debug)

    assert SLog.should_log?(:warning)
    assert SLog.should_log?(:info)
    assert SLog.should_log?(:debug)
    assert SLog.should_log?(:error)
  end

  test "process-level overrides can suppress all logging" do
    SLog.set_process_level(:none)

    refute SLog.should_log?(:warning)
    refute SLog.should_log?(:info)
    refute SLog.should_log?(:debug)
    refute SLog.should_log?(:error)
  end
end
