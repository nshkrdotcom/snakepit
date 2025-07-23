defmodule SnakepitShowcase.Demos.VariablesDemo do
  @moduledoc """
  Demonstrates variable management including registration with types,
  get/set operations, batch operations, and type validation.
  """

  def run do
    IO.puts("📊 Variable Management Demo\n")
    
    session_id = "variables_demo_#{System.unique_integer()}"
    
    # Demo 1: Variable registration
    demo_variable_registration(session_id)
    
    # Demo 2: Get/Set operations
    demo_get_set_operations(session_id)
    
    # Demo 3: Batch operations
    demo_batch_operations(session_id)
    
    # Demo 4: Type validation
    demo_type_validation(session_id)
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup", %{})
    
    :ok
  end

  defp demo_variable_registration(session_id) do
    IO.puts("1️⃣ Variable Registration")
    
    # Register different variable types
    variables = [
      {"temperature", "float", 0.7, %{min: 0.0, max: 1.0}},
      {"max_tokens", "integer", 100, %{min: 1, max: 1000}},
      {"model", "choice", "gpt-4", %{choices: ["gpt-3.5", "gpt-4", "claude"]}},
      {"api_key", "string", "sk-...", %{required: true}},
      {"streaming", "boolean", true, %{}}
    ]
    
    Enum.each(variables, fn {name, type, initial, constraints} ->
      {:ok, result} = Snakepit.execute_in_session(session_id, "register_variable", %{
        name: name,
        type: type,
        initial_value: initial,
        constraints: constraints
      })
      
      IO.puts("   Registered '#{name}' (#{type}): #{inspect(initial)}")
      IO.puts("     Constraints: #{inspect(constraints)}")
    end)
  end

  defp demo_get_set_operations(session_id) do
    IO.puts("\n2️⃣ Get/Set Operations")
    
    # Get initial value
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_variable", %{
      name: "temperature"
    })
    IO.puts("   Initial temperature: #{result["value"]}")
    
    # Update value
    {:ok, _} = Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "temperature",
      value: 0.9
    })
    IO.puts("   Updated temperature to 0.9")
    
    # Get updated value
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_variable", %{
      name: "temperature"
    })
    IO.puts("   New temperature: #{result["value"]}")
    
    # Update with history
    {:ok, result} = Snakepit.execute_in_session(session_id, "set_variable_with_history", %{
      name: "temperature",
      value: 0.5,
      reason: "User requested lower creativity"
    })
    IO.puts("   Updated with history: #{result["version"]}")
  end

  defp demo_batch_operations(session_id) do
    IO.puts("\n3️⃣ Batch Operations")
    
    # Batch get
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_variables", %{
      names: ["temperature", "max_tokens", "model"]
    })
    
    IO.puts("   Batch get results:")
    Enum.each(result["variables"], fn {name, value} ->
      IO.puts("     #{name}: #{inspect(value)}")
    end)
    
    # Batch set
    updates = %{
      "temperature" => 0.8,
      "max_tokens" => 150,
      "model" => "claude"
    }
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "set_variables", %{
      updates: updates
    })
    
    IO.puts("\n   Batch set completed:")
    IO.puts("     Updated: #{result["updated_count"]} variables")
    IO.puts("     Failed: #{result["failed_count"]} variables")
  end

  defp demo_type_validation(session_id) do
    IO.puts("\n4️⃣ Type Validation")
    
    # Test constraint violations
    test_cases = [
      {"temperature", 1.5, "exceeds max constraint"},
      {"temperature", -0.1, "below min constraint"},
      {"max_tokens", "not a number", "wrong type"},
      {"model", "invalid-model", "not in choices"},
      {"streaming", "yes", "not a boolean"}
    ]
    
    Enum.each(test_cases, fn {name, value, expected_error} ->
      case Snakepit.execute_in_session(session_id, "set_variable", %{
        name: name,
        value: value
      }) do
        {:ok, _} ->
          IO.puts("   ❌ Expected validation error for #{name} = #{inspect(value)}")
        {:error, reason} ->
          IO.puts("   ✅ Validation caught: #{name} = #{inspect(value)}")
          IO.puts("      Error: #{expected_error}")
      end
    end)
  end
end