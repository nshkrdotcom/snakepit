defmodule Snakepit.GRPC.BridgeServerTest do
  use ExUnit.Case, async: false

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.GRPC.BridgeServer

  alias Snakepit.Bridge.{
    PingRequest,
    PingResponse,
    InitializeSessionRequest,
    InitializeSessionResponse,
    RegisterVariableRequest,
    RegisterVariableResponse,
    GetVariableRequest,
    GetVariableResponse,
    SetVariableRequest,
    SetVariableResponse,
    BatchGetVariablesRequest,
    BatchGetVariablesResponse,
    BatchSetVariablesRequest,
    BatchSetVariablesResponse
  }

  alias Google.Protobuf.{Any, Timestamp}

  setup do
    # Start SessionStore
    case SessionStore.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Create test session
    session_id = "test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        SessionStore.delete_session(session_id)
      rescue
        _ -> :ok
      end
    end)

    {:ok, session_id: session_id}
  end

  describe "ping/2" do
    test "responds with pong" do
      request = %PingRequest{message: "hello"}
      response = BridgeServer.ping(request, nil)

      assert %PingResponse{} = response
      assert response.message == "pong: hello"
      assert %Timestamp{} = response.server_time
    end
  end

  describe "initialize_session/2" do
    test "creates new session", %{session_id: session_id} do
      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{"source" => "test"}
      }

      response = BridgeServer.initialize_session(request, nil)

      assert %InitializeSessionResponse{} = response
      assert response.success == true
      assert response.error_message == nil
    end

    test "handles duplicate session gracefully", %{session_id: session_id} do
      # First create
      {:ok, _} = SessionStore.create_session(session_id)

      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{}
      }

      # Duplicate init should succeed (idempotent operation)
      response = BridgeServer.initialize_session(request, nil)
      assert response.success == true

      # Session should still exist and be usable
      assert {:ok, _session} = SessionStore.get_session(session_id)
    end
  end

  describe "register_variable/2" do
    setup %{session_id: session_id} do
      {:ok, _} = SessionStore.create_session(session_id)
      :ok
    end

    test "registers float variable", %{session_id: session_id} do
      value_any = encode_test_value(0.7)

      request = %RegisterVariableRequest{
        session_id: session_id,
        name: "temperature",
        type: "float",
        initial_value: value_any,
        constraints_json: Jason.encode!(%{min: 0.0, max: 1.0}),
        metadata: %{"source" => "test"}
      }

      response = BridgeServer.register_variable(request, nil)

      assert %RegisterVariableResponse{} = response
      assert response.success == true
      assert String.starts_with?(response.variable_id, "var_temperature_")
    end

    test "validates constraints", %{session_id: session_id} do
      value_any = encode_test_value(2.0)

      request = %RegisterVariableRequest{
        session_id: session_id,
        name: "percentage",
        type: "float",
        initial_value: value_any,
        constraints_json: Jason.encode!(%{min: 0.0, max: 1.0})
      }

      assert_raise GRPC.RPCError, ~r/above maximum/, fn ->
        BridgeServer.register_variable(request, nil)
      end
    end

    test "handles invalid JSON constraints", %{session_id: session_id} do
      value_any = encode_test_value(0.5)

      request = %RegisterVariableRequest{
        session_id: session_id,
        name: "test",
        type: "float",
        initial_value: value_any,
        constraints_json: "invalid json"
      }

      assert_raise GRPC.RPCError, ~r/Invalid constraints/, fn ->
        BridgeServer.register_variable(request, nil)
      end
    end
  end

  describe "get_variable/2" do
    setup %{session_id: session_id} do
      {:ok, _} = SessionStore.create_session(session_id)

      {:ok, var_id} =
        SessionStore.register_variable(
          session_id,
          :test_var,
          :string,
          "hello world",
          metadata: %{"created_by" => "test"}
        )

      {:ok, var_id: var_id}
    end

    test "gets by ID", %{session_id: session_id, var_id: var_id} do
      request = %GetVariableRequest{
        session_id: session_id,
        variable_identifier: var_id
      }

      response = BridgeServer.get_variable(request, nil)

      assert %GetVariableResponse{} = response
      assert response.variable.id == var_id
      assert response.variable.name == "test_var"
      assert response.variable.type == "string"

      # Decode value
      assert {:ok, "hello world"} = decode_test_value(response.variable.value)
    end

    test "gets by name", %{session_id: session_id} do
      request = %GetVariableRequest{
        session_id: session_id,
        variable_identifier: "test_var"
      }

      response = BridgeServer.get_variable(request, nil)

      assert response.variable.name == "test_var"
    end

    test "handles not found", %{session_id: session_id} do
      request = %GetVariableRequest{
        session_id: session_id,
        variable_identifier: "nonexistent"
      }

      assert_raise GRPC.RPCError, ~r/not found/i, fn ->
        BridgeServer.get_variable(request, nil)
      end
    end
  end

  describe "set_variable/2" do
    setup %{session_id: session_id} do
      {:ok, _} = SessionStore.create_session(session_id)
      {:ok, _} = SessionStore.register_variable(session_id, :counter, :integer, 0)
      :ok
    end

    test "updates value", %{session_id: session_id} do
      value_any = encode_test_value(42)

      request = %SetVariableRequest{
        session_id: session_id,
        variable_identifier: "counter",
        value: value_any,
        metadata: %{"reason" => "test update"}
      }

      response = BridgeServer.set_variable(request, nil)

      assert %SetVariableResponse{} = response
      assert response.success == true
      assert response.new_version == 1

      # Verify the update
      assert SessionStore.get_variable_value(session_id, :counter) == 42
    end

    test "validates type", %{session_id: session_id} do
      value_any = encode_test_value("not a number")

      request = %SetVariableRequest{
        session_id: session_id,
        variable_identifier: "counter",
        value: value_any
      }

      assert_raise GRPC.RPCError, ~r/must be an integer/, fn ->
        BridgeServer.set_variable(request, nil)
      end
    end
  end

  describe "batch operations" do
    setup %{session_id: session_id} do
      {:ok, _} = SessionStore.create_session(session_id)
      {:ok, _} = SessionStore.register_variable(session_id, :var1, :integer, 1)
      {:ok, _} = SessionStore.register_variable(session_id, :var2, :integer, 2)
      {:ok, _} = SessionStore.register_variable(session_id, :var3, :integer, 3)
      :ok
    end

    test "get_variables batch", %{session_id: session_id} do
      request = %BatchGetVariablesRequest{
        session_id: session_id,
        variable_identifiers: ["var1", "var2", "nonexistent"]
      }

      response = BridgeServer.get_variables(request, nil)

      assert %BatchGetVariablesResponse{} = response
      assert map_size(response.variables) == 2
      assert "nonexistent" in response.missing_variables

      # Check found variables
      assert response.variables["var1"].name == "var1"
      assert response.variables["var2"].name == "var2"
    end

    test "set_variables non-atomic", %{session_id: session_id} do
      updates = %{
        "var1" => encode_test_value(10),
        "var2" => encode_test_value(20)
      }

      request = %BatchSetVariablesRequest{
        session_id: session_id,
        updates: updates,
        atomic: false
      }

      response = BridgeServer.set_variables(request, nil)

      assert %BatchSetVariablesResponse{} = response
      assert response.success == true
      assert map_size(response.errors) == 0
      assert response.new_versions["var1"] == 1
      assert response.new_versions["var2"] == 1

      # Verify updates
      assert SessionStore.get_variable_value(session_id, :var1) == 10
      assert SessionStore.get_variable_value(session_id, :var2) == 20
    end

    test "set_variables atomic with failure", %{session_id: session_id} do
      # Add a constrained variable
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :limited,
          :integer,
          5,
          constraints: %{max: 10}
        )

      updates = %{
        "var1" => encode_test_value(100),
        # Will fail constraint
        "limited" => encode_test_value(20)
      }

      request = %BatchSetVariablesRequest{
        session_id: session_id,
        updates: updates,
        atomic: true
      }

      response = BridgeServer.set_variables(request, nil)

      assert response.success == false
      assert Map.has_key?(response.errors, "limited")
      assert map_size(response.new_versions) == 0

      # Verify no updates were applied
      assert SessionStore.get_variable_value(session_id, :var1) == 1
      assert SessionStore.get_variable_value(session_id, :limited) == 5
    end
  end

  # Helper functions

  defp encode_test_value(value) do
    # Infer type from value
    type =
      cond do
        is_boolean(value) -> "boolean"
        is_integer(value) -> "integer"
        is_float(value) -> "float"
        is_binary(value) -> "string"
        true -> "string"
      end

    %Any{
      type_url: "type.googleapis.com/snakepit.#{type}",
      value: Jason.encode!(value)
    }
  end

  defp decode_test_value(%Any{value: encoded}) do
    Jason.decode(encoded)
  end
end
