defmodule Snakepit.Bridge.Variables.VariableTest do
  use ExUnit.Case, async: true

  alias Snakepit.Bridge.Variables.Variable

  describe "new/1" do
    test "creates variable with required fields" do
      attrs = %{
        id: "var_test_123",
        name: :test_var,
        type: :float,
        value: 3.14,
        created_at: System.monotonic_time(:second)
      }

      variable = Variable.new(attrs)

      assert variable.id == "var_test_123"
      assert variable.name == :test_var
      assert variable.type == :float
      assert variable.value == 3.14
      assert variable.version == 0
      assert variable.last_updated_at == variable.created_at
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, ~r/Missing required fields/, fn ->
        Variable.new(%{name: :test})
      end
    end
  end

  describe "update_value/3" do
    setup do
      variable =
        Variable.new(%{
          id: "var_1",
          name: :counter,
          type: :integer,
          value: 0,
          created_at: System.monotonic_time(:second)
        })

      {:ok, variable: variable}
    end

    test "increments version", %{variable: variable} do
      updated = Variable.update_value(variable, 1)
      assert updated.version == 1
      assert updated.value == 1

      updated2 = Variable.update_value(updated, 2)
      assert updated2.version == 2
      assert updated2.value == 2
    end

    test "updates timestamp", %{variable: variable} do
      # Sleep 1 second to ensure monotonic time advances
      Process.sleep(1000)
      updated = Variable.update_value(variable, 1)
      assert updated.last_updated_at > variable.created_at
    end

    test "merges metadata", %{variable: variable} do
      updated = Variable.update_value(variable, 1, metadata: %{"reason" => "test"})
      assert updated.metadata["reason"] == "test"
      assert updated.metadata["source"] == "elixir"
    end
  end

  describe "optimization status" do
    setup do
      variable =
        Variable.new(%{
          id: "var_opt",
          name: :optimizable,
          type: :float,
          value: 0.5,
          created_at: System.monotonic_time(:second)
        })

      {:ok, variable: variable}
    end

    test "not optimizing by default", %{variable: variable} do
      refute Variable.optimizing?(variable)
    end

    test "start_optimization sets status", %{variable: variable} do
      optimized = Variable.start_optimization(variable, "opt_123", self())

      assert Variable.optimizing?(optimized)
      assert optimized.optimization_status.optimizer_id == "opt_123"
      assert optimized.optimization_status.optimizer_pid == self()
      assert is_integer(optimized.optimization_status.started_at)
    end

    test "end_optimization clears status", %{variable: variable} do
      variable = Variable.start_optimization(variable, "opt_123", self())
      assert Variable.optimizing?(variable)

      cleared = Variable.end_optimization(variable)
      refute Variable.optimizing?(cleared)
      assert cleared.optimization_status.optimizer_id == nil
    end
  end

  describe "helper functions" do
    setup do
      now = System.monotonic_time(:second)

      variable =
        Variable.new(%{
          id: "var_helper",
          name: :test,
          type: :string,
          value: "hello",
          created_at: now - 100,
          last_updated_at: now - 50
        })

      {:ok, variable: variable}
    end

    test "age/1 returns time since creation", %{variable: variable} do
      age = Variable.age(variable)
      assert age >= 100
      # Should be close to 100 seconds
      assert age < 110
    end

    test "time_since_update/1 returns time since last update", %{variable: variable} do
      time_since = Variable.time_since_update(variable)
      assert time_since >= 50
      # Should be close to 50 seconds
      assert time_since < 60
    end

    test "to_map/1 converts to plain map", %{variable: variable} do
      map = Variable.to_map(variable)

      assert map.id == variable.id
      assert map.name == to_string(variable.name)
      assert map.type == variable.type
      assert map.value == variable.value
      assert map.version == variable.version
      assert map.optimization_status.optimizing == false
    end
  end
end
