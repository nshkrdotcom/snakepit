defmodule ToolRegistryTest do
  use ExUnit.Case, async: true

  alias Snakepit.Bridge.ToolRegistry

  @table_name :snakepit_tool_registry

  test "registers and retrieves a local tool via the public API" do
    session_id = "sess_#{System.unique_integer([:positive])}"

    handler = fn _params -> {:ok, :done} end
    assert :ok = ToolRegistry.register_elixir_tool(session_id, "echo", handler)

    assert {:ok, tool} = ToolRegistry.get_tool(session_id, "echo")
    assert tool.type == :local
    assert tool.handler == handler
  end

  test "rejects direct ETS writes from external processes" do
    assert_raise ArgumentError, fn ->
      :ets.insert(@table_name, {{"rogue_session", "bad_tool"}, %{type: :remote}})
    end
  end
end
