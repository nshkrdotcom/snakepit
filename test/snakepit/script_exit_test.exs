defmodule Snakepit.ScriptExitTest do
  use ExUnit.Case, async: true

  import Snakepit.Logger.TestHelper

  alias Snakepit.ScriptExit

  setup do
    setup_log_isolation()
  end

  test "exit_mode overrides legacy halt" do
    {exit_mode, warnings} =
      ScriptExit.resolve_exit_mode([exit_mode: :stop, halt: true], %{})

    assert exit_mode == :stop
    assert warnings == []
  end

  test "legacy halt maps to halt when exit_mode is unset" do
    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([halt: true], %{})

    assert exit_mode == :halt
    assert warnings == []
  end

  test "halt option overrides env exit selection" do
    env = %{
      "SNAKEPIT_SCRIPT_EXIT" => "stop",
      "SNAKEPIT_SCRIPT_HALT" => "true"
    }

    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([halt: true], env)

    assert exit_mode == :halt
    assert warnings == []
  end

  test "env exit selection overrides legacy env halt" do
    env = %{
      "SNAKEPIT_SCRIPT_EXIT" => "stop",
      "SNAKEPIT_SCRIPT_HALT" => "true"
    }

    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([], env)

    assert exit_mode == :stop
    assert warnings == []
  end

  test "empty env exit value is treated as unset" do
    env = %{"SNAKEPIT_SCRIPT_EXIT" => "   ", "SNAKEPIT_SCRIPT_HALT" => "yes"}

    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([], env)

    assert exit_mode == :halt
    assert warnings == []
  end

  test "default exit_mode is :none when nothing is set" do
    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([], %{})

    assert exit_mode == :none
    assert warnings == []
  end

  test "SNAKEPIT_SCRIPT_EXIT parsing is trim and case-insensitive" do
    env = %{"SNAKEPIT_SCRIPT_EXIT" => "  HaLt  "}

    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([], env)

    assert exit_mode == :halt
    assert warnings == []
  end

  test "invalid SNAKEPIT_SCRIPT_EXIT is ignored and warns" do
    env = %{
      "SNAKEPIT_SCRIPT_EXIT" => "bogus",
      "SNAKEPIT_SCRIPT_HALT" => "true"
    }

    {exit_mode, warnings} = ScriptExit.resolve_exit_mode([], env)

    assert exit_mode == :halt

    log =
      capture_at_level(:warning, fn ->
        ScriptExit.log_warnings(warnings)
      end)

    assert log =~ "SNAKEPIT_SCRIPT_EXIT"
    assert log =~ "bogus"
    assert log =~ "halt"
  end

  test "auto resolves to stop only when owned and no_halt" do
    assert ScriptExit.resolve_auto_exit_mode(:auto, true, true) == :stop
    assert ScriptExit.resolve_auto_exit_mode(:auto, true, false) == :none
    assert ScriptExit.resolve_auto_exit_mode(:auto, false, true) == :none
  end
end
