defmodule Snakepit.Bridge.SessionStoreVariablesTest do
  use ExUnit.Case, async: false

  alias Snakepit.Bridge.SessionStore

  setup do
    # Ensure SessionStore is started
    case SessionStore.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Create test session
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, _} = SessionStore.create_session(session_id)

    on_exit(fn ->
      SessionStore.delete_session(session_id)
    end)

    {:ok, session_id: session_id}
  end

  describe "register_variable/5" do
    test "registers variable with type validation", %{session_id: session_id} do
      {:ok, var_id} =
        SessionStore.register_variable(
          session_id,
          :temperature,
          :float,
          0.7,
          constraints: %{min: 0.0, max: 2.0},
          description: "LLM temperature"
        )

      assert String.starts_with?(var_id, "var_temperature_")

      {:ok, variable} = SessionStore.get_variable(session_id, var_id)
      assert variable.name == :temperature
      assert variable.type == :float
      assert variable.value == 0.7
      assert variable.constraints.min == 0.0
      assert variable.metadata["description"] == "LLM temperature"
    end

    test "rejects invalid type", %{session_id: session_id} do
      assert {:error, {:unknown_type, :invalid}} =
               SessionStore.register_variable(session_id, :bad, :invalid, "value")
    end

    test "enforces type validation", %{session_id: session_id} do
      assert {:error, _} =
               SessionStore.register_variable(session_id, :count, :integer, "not a number")
    end

    test "enforces constraints", %{session_id: session_id} do
      assert {:error, _} =
               SessionStore.register_variable(
                 session_id,
                 :percentage,
                 :float,
                 1.5,
                 constraints: %{min: 0.0, max: 1.0}
               )
    end
  end

  describe "get_variable/2" do
    setup %{session_id: session_id} do
      {:ok, var_id} =
        SessionStore.register_variable(
          session_id,
          :test_var,
          :string,
          "hello"
        )

      {:ok, var_id: var_id}
    end

    test "gets by ID", %{session_id: session_id, var_id: var_id} do
      {:ok, variable} = SessionStore.get_variable(session_id, var_id)
      assert variable.value == "hello"
    end

    test "gets by name (string)", %{session_id: session_id} do
      {:ok, variable} = SessionStore.get_variable(session_id, "test_var")
      assert variable.value == "hello"
    end

    test "gets by name (atom)", %{session_id: session_id} do
      {:ok, variable} = SessionStore.get_variable(session_id, :test_var)
      assert variable.value == "hello"
    end

    test "returns error for non-existent", %{session_id: session_id} do
      assert {:error, :not_found} = SessionStore.get_variable(session_id, :nonexistent)
    end

    test "get_variable_value convenience function", %{session_id: session_id} do
      assert SessionStore.get_variable_value(session_id, :test_var) == "hello"
      assert SessionStore.get_variable_value(session_id, :missing, "default") == "default"
    end
  end

  describe "update_variable/4" do
    setup %{session_id: session_id} do
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :counter,
          :integer,
          0,
          constraints: %{min: 0, max: 100}
        )

      :ok
    end

    test "updates value and increments version", %{session_id: session_id} do
      assert :ok = SessionStore.update_variable(session_id, :counter, 42)

      {:ok, variable} = SessionStore.get_variable(session_id, :counter)
      assert variable.value == 42
      assert variable.version == 1

      assert :ok = SessionStore.update_variable(session_id, :counter, 50)

      {:ok, variable} = SessionStore.get_variable(session_id, :counter)
      assert variable.value == 50
      assert variable.version == 2
    end

    test "enforces constraints on update", %{session_id: session_id} do
      assert {:error, _} = SessionStore.update_variable(session_id, :counter, 150)

      # Value should remain unchanged
      {:ok, variable} = SessionStore.get_variable(session_id, :counter)
      assert variable.value == 0
      assert variable.version == 0
    end

    test "adds metadata", %{session_id: session_id} do
      assert :ok =
               SessionStore.update_variable(
                 session_id,
                 :counter,
                 1,
                 %{"reason" => "increment", "user" => "test"}
               )

      {:ok, variable} = SessionStore.get_variable(session_id, :counter)
      assert variable.metadata["reason"] == "increment"
      assert variable.metadata["user"] == "test"
    end
  end

  describe "batch operations" do
    setup %{session_id: session_id} do
      # Register multiple variables
      {:ok, _} = SessionStore.register_variable(session_id, :a, :integer, 1)
      {:ok, _} = SessionStore.register_variable(session_id, :b, :integer, 2)
      {:ok, _} = SessionStore.register_variable(session_id, :c, :integer, 3)

      :ok
    end

    test "get_variables/2", %{session_id: session_id} do
      {:ok, result} =
        SessionStore.get_variables(
          session_id,
          [:a, :b, :nonexistent, "c"]
        )

      assert map_size(result.found) == 3
      assert result.found["a"].value == 1
      assert result.found["b"].value == 2
      assert result.found["c"].value == 3
      assert result.missing == ["nonexistent"]
    end

    test "update_variables/3 non-atomic", %{session_id: session_id} do
      updates = %{
        a: 10,
        b: 20,
        c: 30
      }

      {:ok, results} = SessionStore.update_variables(session_id, updates)

      assert results["a"] == :ok
      assert results["b"] == :ok
      assert results["c"] == :ok

      # Verify updates
      assert SessionStore.get_variable_value(session_id, :a) == 10
      assert SessionStore.get_variable_value(session_id, :b) == 20
      assert SessionStore.get_variable_value(session_id, :c) == 30
    end

    test "update_variables/3 atomic with validation failure", %{session_id: session_id} do
      # Add constraint to one variable
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :constrained,
          :integer,
          5,
          constraints: %{max: 10}
        )

      updates = %{
        a: 100,
        # Will fail
        constrained: 20
      }

      {:error, {:validation_failed, errors}} =
        SessionStore.update_variables(session_id, updates, atomic: true)

      assert Map.has_key?(errors, "constrained")

      # No updates should have been applied
      assert SessionStore.get_variable_value(session_id, :a) == 1
      assert SessionStore.get_variable_value(session_id, :constrained) == 5
    end

    test "update_variables/3 non-atomic partial success", %{session_id: session_id} do
      # Add constraint to one variable
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :limited,
          :integer,
          5,
          constraints: %{max: 10}
        )

      updates = %{
        a: 100,
        # Will fail
        limited: 20
      }

      {:ok, results} = SessionStore.update_variables(session_id, updates, atomic: false)

      # Check results
      assert results["a"] == :ok
      assert match?({:error, _}, results["limited"])

      # :a should be updated, :limited should not
      assert SessionStore.get_variable_value(session_id, :a) == 100
      assert SessionStore.get_variable_value(session_id, :limited) == 5
    end
  end

  describe "list_variables/1,2" do
    setup %{session_id: session_id} do
      # Register variables with patterns
      {:ok, _} = SessionStore.register_variable(session_id, :temp_cpu, :float, 45.0)
      {:ok, _} = SessionStore.register_variable(session_id, :temp_gpu, :float, 60.0)
      {:ok, _} = SessionStore.register_variable(session_id, :memory, :integer, 1024)

      :ok
    end

    test "lists all variables", %{session_id: session_id} do
      {:ok, variables} = SessionStore.list_variables(session_id)
      assert length(variables) == 3

      names = Enum.map(variables, & &1.name)
      assert :temp_cpu in names
      assert :temp_gpu in names
      assert :memory in names
    end

    test "lists by pattern", %{session_id: session_id} do
      {:ok, temps} = SessionStore.list_variables(session_id, "temp_*")
      assert length(temps) == 2

      assert Enum.all?(temps, fn v ->
               String.starts_with?(to_string(v.name), "temp_")
             end)
    end
  end

  describe "delete_variable/2" do
    setup %{session_id: session_id} do
      {:ok, var_id} =
        SessionStore.register_variable(
          session_id,
          :deletable,
          :string,
          "delete me"
        )

      {:ok, var_id: var_id}
    end

    test "deletes by ID", %{session_id: session_id, var_id: var_id} do
      assert :ok = SessionStore.delete_variable(session_id, var_id)
      assert {:error, :not_found} = SessionStore.get_variable(session_id, var_id)
    end

    test "deletes by name", %{session_id: session_id} do
      assert :ok = SessionStore.delete_variable(session_id, :deletable)
      assert {:error, :not_found} = SessionStore.get_variable(session_id, :deletable)
    end

    test "delete non-existent returns error", %{session_id: session_id} do
      assert {:error, :not_found} = SessionStore.delete_variable(session_id, :nonexistent)
    end
  end

  describe "has_variable?/2" do
    setup %{session_id: session_id} do
      {:ok, _} = SessionStore.register_variable(session_id, :exists, :boolean, true)
      :ok
    end

    test "returns true for existing variable", %{session_id: session_id} do
      assert SessionStore.has_variable?(session_id, :exists)
      assert SessionStore.has_variable?(session_id, "exists")
    end

    test "returns false for non-existent variable", %{session_id: session_id} do
      refute SessionStore.has_variable?(session_id, :missing)
      refute SessionStore.has_variable?(session_id, "missing")
    end
  end

  describe "export/import variables" do
    setup %{session_id: session_id} do
      # Create some variables
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :export_test,
          :string,
          "test value",
          constraints: %{min_length: 1},
          metadata: %{"custom" => "data"}
        )

      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :export_num,
          :integer,
          42
        )

      :ok
    end

    test "export_variables/1", %{session_id: session_id} do
      {:ok, exported} = SessionStore.export_variables(session_id)

      assert length(exported) == 2
      assert Enum.all?(exported, &is_map/1)

      # Find the string variable
      string_var = Enum.find(exported, &(&1.name == "export_test"))
      assert string_var.type == :string
      assert string_var.value == "test value"
      assert string_var.constraints == %{min_length: 1}
    end

    test "import_variables/2", %{session_id: session_id} do
      # Create a new session for import
      import_session_id = "import_session_#{System.unique_integer([:positive])}"
      {:ok, _} = SessionStore.create_session(import_session_id)

      on_exit(fn ->
        SessionStore.delete_session(import_session_id)
      end)

      # Export from original
      {:ok, exported} = SessionStore.export_variables(session_id)

      # Import to new session
      {:ok, count} = SessionStore.import_variables(import_session_id, exported)
      assert count == 2

      # Verify imported variables
      assert SessionStore.get_variable_value(import_session_id, :export_test) == "test value"
      assert SessionStore.get_variable_value(import_session_id, :export_num) == 42
    end
  end

  describe "edge cases" do
    test "variable operations on non-existent session" do
      bad_session = "nonexistent_session"

      assert {:error, :session_not_found} =
               SessionStore.register_variable(bad_session, :test, :string, "value")

      assert {:error, :session_not_found} =
               SessionStore.get_variable(bad_session, :test)

      assert {:error, :session_not_found} =
               SessionStore.update_variable(bad_session, :test, "new")

      assert {:error, :session_not_found} =
               SessionStore.list_variables(bad_session)
    end

    test "type coercion", %{session_id: session_id} do
      # Integer to float coercion
      {:ok, _} =
        SessionStore.register_variable(
          session_id,
          :coerce_test,
          :float,
          # Integer value for float type
          42
        )

      {:ok, var} = SessionStore.get_variable(session_id, :coerce_test)
      assert var.value == 42.0
      assert is_float(var.value)
    end

    test "concurrent variable updates", %{session_id: session_id} do
      {:ok, _} = SessionStore.register_variable(session_id, :concurrent, :integer, 0)

      # Spawn multiple processes to update the same variable
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            SessionStore.update_variable(session_id, :concurrent, i)
          end)
        end

      # Wait for all updates
      Task.await_many(tasks)

      # The final value should be one of the updates
      final_value = SessionStore.get_variable_value(session_id, :concurrent)
      assert final_value in 1..10
    end
  end
end
