defmodule Snakepit.ScriptStopTest do
  use ExUnit.Case, async: true

  alias Snakepit.ScriptStop

  test "stop_mode defaults to :if_started" do
    assert ScriptStop.resolve_stop_mode([]) == :if_started
  end

  test "stop_mode validates supported values" do
    assert ScriptStop.resolve_stop_mode(stop_mode: :always) == :always
    assert ScriptStop.resolve_stop_mode(stop_mode: :never) == :never

    assert_raise ArgumentError, fn ->
      ScriptStop.resolve_stop_mode(stop_mode: :bogus)
    end
  end

  test "stop_mode :if_started only stops when owned" do
    assert ScriptStop.stop_snakepit?(:if_started, true)
    refute ScriptStop.stop_snakepit?(:if_started, false)
  end

  test "stop_mode :always stops regardless of ownership" do
    assert ScriptStop.stop_snakepit?(:always, true)
    assert ScriptStop.stop_snakepit?(:always, false)
  end

  test "stop_mode :never never stops" do
    refute ScriptStop.stop_snakepit?(:never, true)
    refute ScriptStop.stop_snakepit?(:never, false)
  end
end
