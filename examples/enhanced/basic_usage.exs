#!/usr/bin/env elixir

# Basic Enhanced Python Bridge Usage Examples
# 
# This script demonstrates the core capabilities of the enhanced Python bridge
# including dynamic method calls, object persistence, and framework integration.

# Configure Snakepit to use the enhanced Python adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.EnhancedPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Stop the application if it's running
Application.stop(:snakepit)

# Start the application with new configuration
{:ok, _} = Application.ensure_all_started(:snakepit)

IO.puts("=== Enhanced Python Bridge Examples ===\n")

# 1. Basic bridge information
IO.puts("1. Bridge Information:")
case Snakepit.Python.info() do
  {:ok, info} ->
    IO.puts("   Bridge Type: #{info["bridge_type"]}")
    IO.puts("   Frameworks: #{Enum.join(info["frameworks_available"], ", ")}")
    IO.puts("   Stored Objects: #{info["stored_objects"]}")
  {:error, error} ->
    IO.puts("   Error: #{error}")
end
IO.puts("")

# 2. Basic Python calls
IO.puts("2. Basic Python Operations:")

# Math operations (use positional args)
case Snakepit.Python.call("math.sqrt", %{}, args: [16]) do
  {:ok, result} ->
    IO.puts("   math.sqrt(16) = #{inspect(result)}")
  {:error, error} ->
    IO.puts("   Error: #{error}")
end

# String operations (create string first, then call method)
case Snakepit.Python.call("str", %{}, args: ["hello world"], store_as: "my_string") do
  {:ok, result} ->
    IO.puts("   Created string: #{inspect(result)}")
    
    # Now call upper on the stored string
    case Snakepit.Python.call("stored.my_string.upper", %{}) do
      {:ok, upper_result} ->
        IO.puts("   'hello world'.upper() = #{inspect(upper_result)}")
      {:error, error} ->
        IO.puts("   Error calling upper: #{error}")
    end
  {:error, error} ->
    IO.puts("   Error creating string: #{error}")
end

IO.puts("")

# 3. Object storage and retrieval
IO.puts("3. Object Storage:")

# Store a simple value
case Snakepit.Python.store("my_number", 42) do
  {:ok, result} ->
    IO.puts("   Stored number: #{inspect(result)}")
  {:error, error} ->
    IO.puts("   Error storing: #{error}")
end

# Retrieve the value
case Snakepit.Python.retrieve("my_number") do
  {:ok, result} ->
    IO.puts("   Retrieved: #{inspect(result)}")
  {:error, error} ->
    IO.puts("   Error retrieving: #{error}")
end

# List stored objects
case Snakepit.Python.list_stored() do
  {:ok, result} ->
    IO.puts("   Stored objects: #{inspect(result["stored_objects"])}")
  {:error, error} ->
    IO.puts("   Error listing: #{error}")
end

IO.puts("")

# 4. Framework integration (if available)
IO.puts("4. Framework Integration:")

# Try to create a simple data structure
case Snakepit.Python.call("collections.defaultdict", %{default_factory: "list"}, store_as: "my_dict") do
  {:ok, result} ->
    IO.puts("   Created defaultdict: #{inspect(result)}")
    
    # Add some data to it (use positional args)
    case Snakepit.Python.call("stored.my_dict.__getitem__", %{}, args: ["fruits"]) do
      {:ok, fruits_list} ->
        IO.puts("   Accessed my_dict['fruits']: #{inspect(fruits_list)}")
      {:error, error} ->
        IO.puts("   Error accessing dict: #{error}")
    end
    
  {:error, error} ->
    IO.puts("   Error creating defaultdict: #{error}")
end

IO.puts("")

# 5. Inspection capabilities
IO.puts("5. Object Inspection:")

case Snakepit.Python.inspect("math.sqrt") do
  {:ok, result} ->
    inspection = result["inspection"]
    IO.puts("   Object: math.sqrt")
    IO.puts("   Type: #{inspection["type"]}")
    IO.puts("   Module: #{inspection["module"]}")
    IO.puts("   Callable: #{inspection["callable"]}")
    if inspection["signature"] do
      IO.puts("   Signature: #{inspection["signature"]}")
    end
  {:error, error} ->
    IO.puts("   Error inspecting: #{error}")
end

IO.puts("")

# 6. Pipeline execution
IO.puts("6. Pipeline Execution:")

pipeline_steps = [
  {:call, "str", %{}, [args: ["HELLO WORLD"], store_as: "temp_string"]},
  {:call, "stored.temp_string.lower", %{}}
]

case Snakepit.Python.pipeline(pipeline_steps) do
  {:ok, result} ->
    IO.puts("   Pipeline completed: #{result["steps_completed"]} steps")
    results = result["pipeline_results"] || []
    if length(results) > 0 do
      Enum.with_index(results, fn step_result, index ->
        IO.puts("   Step #{index + 1}: #{inspect(step_result["result"])}")
      end)
    else
      IO.puts("   No results to display")
    end
  {:error, error} ->
    IO.puts("   Pipeline error: #{error}")
end

IO.puts("")

# 7. Session-based operations
IO.puts("7. Session-based Operations:")

session_id = Snakepit.Python.create_session()
case session_id do
  {:error, error} ->
    IO.puts("   Error creating session: #{error}")
  session_id when is_binary(session_id) ->
    IO.puts("   Created session: #{session_id}")
    
    # Store something in the session
    case Snakepit.Python.store("session_data", "This is session-specific", session_id: session_id) do
      {:ok, _} ->
        IO.puts("   Stored session data")
        
        # Retrieve from the same session
        case Snakepit.Python.retrieve("session_data", session_id: session_id) do
          {:ok, result} ->
            IO.puts("   Retrieved from session: #{inspect(result)}")
          {:error, error} ->
            IO.puts("   Error retrieving from session: #{error}")
        end
        
      {:error, error} ->
        IO.puts("   Error storing in session: #{error}")
    end
end

IO.puts("")

# 8. Error handling demonstration
IO.puts("8. Error Handling:")

# Try to call a non-existent method
case Snakepit.Python.call("nonexistent.method", %{}) do
  {:ok, result} ->
    IO.puts("   Unexpected success: #{inspect(result)}")
  {:error, error} ->
    IO.puts("   Expected error: #{error}")
end

# Try to retrieve a non-existent object
case Snakepit.Python.retrieve("nonexistent") do
  {:ok, result} ->
    IO.puts("   Unexpected success: #{inspect(result)}")
  {:error, error} ->
    IO.puts("   Expected error: #{error}")
end

IO.puts("")

# Clean up
case Snakepit.Python.list_stored() do
  {:ok, result} ->
    stored_objects = result["stored_objects"]
    IO.puts("9. Cleanup:")
    IO.puts("   Cleaning up #{length(stored_objects)} stored objects...")
    
    Enum.each(stored_objects, fn object_id ->
      case Snakepit.Python.delete_stored(object_id) do
        {:ok, _} ->
          IO.puts("   Deleted: #{object_id}")
        {:error, error} ->
          IO.puts("   Error deleting #{object_id}: #{error}")
      end
    end)
  {:error, error} ->
    IO.puts("   Error listing objects for cleanup: #{error}")
end

IO.puts("\n=== Examples Complete ===")