defmodule Snakepit.Bridge.SessionIntegrationTest do
  @moduledoc """
  Integration tests for the SessionStore and bridge components.

  These tests verify the Elixir-side implementation without requiring
  Python gRPC workers.
  """

  use ExUnit.Case, async: false

  alias Snakepit.Bridge.{SessionStore, Serialization}

  @moduletag :integration

  setup_all do
    # Ensure the application is started
    Application.ensure_all_started(:snakepit)
    {:ok, %{}}
  end

  describe "SessionStore Integration" do
    setup do
      session_id = "integration_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = SessionStore.create_session(session_id)

      on_exit(fn ->
        SessionStore.delete_session(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "complete variable lifecycle", %{session_id: session_id} do
      # Register various variable types
      variables = [
        %{name: "int_var", type: :integer, value: 42, constraints: %{min: 0, max: 100}},
        %{name: "float_var", type: :float, value: 3.14, constraints: %{min: 0.0, max: 10.0}},
        %{name: "string_var", type: :string, value: "hello", constraints: %{pattern: "^[a-z]+$"}},
        %{name: "bool_var", type: :boolean, value: true}
      ]

      # Register all variables
      for var <- variables do
        assert {:ok, _} =
                 SessionStore.register_variable(
                   session_id,
                   var.name,
                   var.type,
                   var.value,
                   constraints: Map.get(var, :constraints, %{})
                 )
      end

      # List all variables
      assert {:ok, listed} = SessionStore.list_variables(session_id, "*")
      assert length(listed) == length(variables)

      # Get and verify each variable
      for var <- variables do
        assert {:ok, retrieved} = SessionStore.get_variable(session_id, var.name)
        assert retrieved.name == var.name
        assert retrieved.type == var.type
        assert retrieved.value == var.value
      end

      # Update variables
      assert :ok = SessionStore.update_variable(session_id, "int_var", 50)
      assert :ok = SessionStore.update_variable(session_id, "float_var", 2.71)
      assert :ok = SessionStore.update_variable(session_id, "string_var", "world")

      # Verify updates
      assert {:ok, var} = SessionStore.get_variable(session_id, "int_var")
      assert var.value == 50

      # Test constraint violations
      # > max
      assert {:error, _} = SessionStore.update_variable(session_id, "int_var", 150)
      # < min
      assert {:error, _} = SessionStore.update_variable(session_id, "float_var", -1.0)
      # pattern mismatch
      assert {:error, _} = SessionStore.update_variable(session_id, "string_var", "CAPS")

      # Delete a variable
      assert :ok = SessionStore.delete_variable(session_id, "bool_var")

      # Verify deletion
      assert {:error, :not_found} = SessionStore.get_variable(session_id, "bool_var")
    end

    test "session isolation", %{session_id: session_id} do
      # Create another session
      other_session = "other_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = SessionStore.create_session(other_session)

      # Register same variable name in both sessions
      assert {:ok, _} = SessionStore.register_variable(session_id, "shared", :integer, 10)
      assert {:ok, _} = SessionStore.register_variable(other_session, "shared", :integer, 20)

      # Verify isolation
      assert {:ok, var1} = SessionStore.get_variable(session_id, "shared")
      assert {:ok, var2} = SessionStore.get_variable(other_session, "shared")
      assert var1.value == 10
      assert var2.value == 20

      # Clean up
      SessionStore.delete_session(other_session)
    end

    test "batch operations", %{session_id: session_id} do
      # Register multiple variables
      for i <- 1..10 do
        assert {:ok, _} =
                 SessionStore.register_variable(
                   session_id,
                   "batch_#{i}",
                   :integer,
                   i * 10
                 )
      end

      # Batch get
      names = for(i <- 1..5, do: "batch_#{i}")
      assert {:ok, result} = SessionStore.get_variables(session_id, names)
      assert map_size(result.found) == 5
      assert result.missing == []

      # Batch update
      updates = for i <- 1..5, do: {"batch_#{i}", i * 100}
      assert {:ok, results} = SessionStore.update_variables(session_id, Map.new(updates))
      assert map_size(results) == 5

      # Verify updates
      for i <- 1..5 do
        assert {:ok, var} = SessionStore.get_variable(session_id, "batch_#{i}")
        assert var.value == i * 100
      end
    end
  end

  describe "Serialization Integration" do
    test "all type round trips" do
      test_cases = [
        {:integer, 42},
        {:float, 3.14159},
        {:string, "Hello, 世界"},
        {:boolean, true},
        {:boolean, false},
        {:integer, 0},
        {:integer, -1},
        {:float, 0.0},
        {:float, -0.0},
        {:string, ""},
        # max int32
        {:integer, 2_147_483_647},
        # near max float64
        {:float, 1.7976931348623157e+308},
        {:string, String.duplicate("a", 1000)}
      ]

      for {type, value} <- test_cases do
        assert {:ok, encoded} = Serialization.encode_any(value, type)
        assert is_binary(encoded.type_url)
        assert is_binary(encoded.value)
        assert String.starts_with?(encoded.type_url, "type.googleapis.com/snakepit.")

        assert {:ok, decoded} = Serialization.decode_any(encoded)
        assert decoded == value
      end
    end
  end
end
