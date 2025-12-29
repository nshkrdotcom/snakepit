defmodule Snakepit.Logger.TestHelper do
  @moduledoc """
  Test isolation helpers for Snakepit.Logger.

  This module provides utilities for setting up per-process log level
  isolation in tests. This prevents async tests from interfering with
  each other's log level configurations.

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case, async: true

        import Snakepit.Logger.TestHelper

        setup do
          setup_log_isolation()
        end

        test "captures warning logs" do
          log = capture_at_level(:warning, fn ->
            Snakepit.Logger.warning(:pool, "test message")
          end)

          assert log =~ "test message"
        end
      end

  ## Integration with Supertester

  If you're using Supertester's `LoggerIsolation`, this module will
  respect the Elixir Logger's per-process level settings.
  """

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Snakepit.Logger, as: SLog

  @doc """
  Set up log level isolation for the current test process.

  Call this in your test setup to ensure log level changes don't
  affect other concurrent tests.

  Returns `:ok` and registers an `on_exit` callback to restore
  the original log level.

  ## Example

      setup do
        setup_log_isolation()
      end

  """
  @spec setup_log_isolation() :: :ok
  def setup_log_isolation do
    original = Process.get(:snakepit_log_level_override)

    ExUnit.Callbacks.on_exit(fn ->
      if original do
        Process.put(:snakepit_log_level_override, original)
      else
        Process.delete(:snakepit_log_level_override)
      end
    end)

    :ok
  end

  @doc """
  Capture logs at a specific log level without affecting other tests.

  This combines `Snakepit.Logger.with_level/2` with `ExUnit.CaptureLog.capture_log/1`
  to provide isolated log capture.

  ## Example

      log = capture_at_level(:warning, fn ->
        Snakepit.Logger.warning(:pool, "pool warning")
        Snakepit.Logger.debug(:pool, "debug - won't appear")
      end)

      assert log =~ "pool warning"
      refute log =~ "debug"

  """
  @spec capture_at_level(SLog.level(), (-> term())) :: String.t()
  def capture_at_level(level, fun) when is_function(fun, 0) do
    SLog.with_level(level, fn ->
      capture_log(fun)
    end)
  end

  @doc """
  Capture logs at a specific level and return both the log and result.

  ## Example

      {log, result} = capture_at_level_with_result(:info, fn ->
        Snakepit.Logger.info(:pool, "info message")
        :some_result
      end)

      assert log =~ "info message"
      assert result == :some_result

  """
  @spec capture_at_level_with_result(SLog.level(), (-> result)) :: {String.t(), result}
        when result: term()
  def capture_at_level_with_result(level, fun) when is_function(fun, 0) do
    result_ref = make_ref()

    log =
      SLog.with_level(level, fn ->
        capture_log(fn ->
          result = fun.()
          Process.put(result_ref, result)
        end)
      end)

    result = Process.get(result_ref)
    Process.delete(result_ref)
    {log, result}
  end

  @doc """
  Suppress all Snakepit logs for the duration of a function.

  Useful when testing code that logs but you don't care about the output.

  ## Example

      suppress_logs(fn ->
        # Code that logs a lot but we don't care
        noisy_function()
      end)

  """
  @spec suppress_logs((-> result)) :: result when result: term()
  def suppress_logs(fun) when is_function(fun, 0) do
    SLog.with_level(:none, fun)
  end
end
