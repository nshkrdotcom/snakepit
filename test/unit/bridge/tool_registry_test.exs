defmodule ToolRegistryTest do
  use ExUnit.Case, async: true
  alias Snakepit.Bridge.InternalToolSpec
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

  test "returns tuple reason when tool is missing" do
    session_id = "sess_missing_#{System.unique_integer([:positive])}"

    assert {:error, {:tool_not_found, ^session_id, "missing"}} =
             ToolRegistry.get_tool(session_id, "missing")
  end

  test "rejects invalid tool names" do
    session_id = "sess_invalid_#{System.unique_integer([:positive])}"
    handler = fn _ -> {:ok, :ok} end

    assert {:error, {:invalid_tool_name, :invalid_format}} =
             ToolRegistry.register_elixir_tool(session_id, "invalid name", handler)
  end

  test "rejects oversized metadata payloads" do
    session_id = "sess_meta_#{System.unique_integer([:positive])}"
    big_metadata = %{details: String.duplicate("x", 4_200)}

    assert {:error, {:invalid_metadata, :too_large}} ==
             ToolRegistry.register_python_tool(session_id, "heavy", "worker_1", big_metadata)
  end

  test "prevents duplicate registrations for the same session" do
    session_id = "sess_dup_#{System.unique_integer([:positive])}"

    assert :ok = ToolRegistry.register_python_tool(session_id, "dup_tool", "worker_a", %{})

    assert {:error, {:duplicate_tool, "dup_tool"}} ==
             ToolRegistry.register_python_tool(session_id, "dup_tool", "worker_b", %{})
  end

  test "rejects duplicate tool names within a batch registration" do
    session_id = "sess_batch_dup_#{System.unique_integer([:positive])}"

    specs = [
      %{
        name: "dup",
        description: "",
        parameters: [],
        metadata: %{},
        worker_id: "worker_a"
      },
      %{
        name: "dup",
        description: "",
        parameters: [],
        metadata: %{},
        worker_id: "worker_b"
      }
    ]

    assert {:error, {:duplicate_tool, "dup"}} = ToolRegistry.register_tools(session_id, specs)
  end

  test "rejects direct ETS writes from external processes" do
    assert_raise ArgumentError, fn ->
      :ets.insert(@table_name, {{"rogue_session", "bad_tool"}, %{type: :remote}})
    end
  end

  test "cleanup_session removes tools for the session" do
    session_id = "sess_cleanup_#{System.unique_integer([:positive])}"

    assert :ok = ToolRegistry.register_python_tool(session_id, "one", "worker_a", %{})
    assert :ok = ToolRegistry.register_python_tool(session_id, "two", "worker_b", %{})

    assert length(ToolRegistry.list_tools(session_id)) == 2

    assert :ok = ToolRegistry.cleanup_session(session_id)
    assert ToolRegistry.list_tools(session_id) == []
  end

  test "execute_local_tool returns tuple reasons for type and execution errors" do
    session_id = "sess_exec_errors_#{System.unique_integer([:positive])}"
    remote_tool = "remote_only"
    local_tool = "boom_tool"

    assert :ok = ToolRegistry.register_python_tool(session_id, remote_tool, "worker_a", %{})

    assert {:error, {:tool_not_local, ^remote_tool}} =
             ToolRegistry.execute_local_tool(session_id, remote_tool, %{})

    assert :ok =
             ToolRegistry.register_elixir_tool(session_id, local_tool, fn _params ->
               raise "boom"
             end)

    assert {:error, {:tool_execution_failed, %RuntimeError{message: "boom"}}} =
             ToolRegistry.execute_local_tool(session_id, local_tool, %{})
  end

  test "InternalToolSpec enforces required keys" do
    assert_raise ArgumentError, fn ->
      struct!(InternalToolSpec, %{name: "only_name"})
    end

    assert_raise ArgumentError, fn ->
      struct!(InternalToolSpec, %{type: :local})
    end
  end
end
