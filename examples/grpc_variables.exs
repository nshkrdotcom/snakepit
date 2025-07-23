#!/usr/bin/env elixir

# Variable Management with gRPC Example
# Demonstrates type-safe variable registration, constraints, and validation

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Start the Snakepit application
{:ok, _} = Application.ensure_all_started(:snakepit)

defmodule VariableExample do
  def run do
    IO.puts("\n=== Variable Management Example ===\n")
    
    session_id = "var_demo_#{System.unique_integer([:positive])}"
    
    # 1. Register different variable types
    IO.puts("1. Registering variables with different types:")
    
    # Integer with constraints
    {:ok, int_var} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "user_age",
      type: "integer",
      initial_value: 25,
      constraints: %{min: 0, max: 150},
      metadata: %{description: "User's age in years"}
    })
    IO.puts("  ✓ Integer variable: #{int_var["id"]}")
    
    # Float with precision
    {:ok, float_var} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "temperature",
      type: "float",
      initial_value: 20.5,
      constraints: %{min: -273.15, max: 1000.0},
      metadata: %{unit: "celsius", precision: 0.1}
    })
    IO.puts("  ✓ Float variable: #{float_var["id"]}")
    
    # String with pattern
    {:ok, string_var} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "email",
      type: "string",
      initial_value: "user@example.com",
      constraints: %{
        pattern: "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$",
        max_length: 255
      }
    })
    IO.puts("  ✓ String variable: #{string_var["id"]}")
    
    # Boolean
    {:ok, bool_var} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "is_active",
      type: "boolean",
      initial_value: true
    })
    IO.puts("  ✓ Boolean variable: #{bool_var["id"]}")
    
    # Choice type
    {:ok, choice_var} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "status",
      type: "choice",
      initial_value: "pending",
      constraints: %{choices: ["pending", "active", "completed", "cancelled"]}
    })
    IO.puts("  ✓ Choice variable: #{choice_var["id"]}")
    
    # 2. Constraint validation
    IO.puts("\n2. Testing constraint validation:")
    
    # Valid update
    case Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "user_age",
      value: 30
    }) do
      {:ok, _} -> IO.puts("  ✓ Valid age update: 30")
      {:error, reason} -> IO.puts("  ✗ Error: #{inspect(reason)}")
    end
    
    # Invalid update (out of range)
    case Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "user_age",
      value: 200
    }) do
      {:ok, _} -> IO.puts("  ✗ Should have failed!")
      {:error, reason} -> IO.puts("  ✓ Expected error for age=200: #{inspect(reason)}")
    end
    
    # Invalid email format
    case Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "email",
      value: "invalid-email"
    }) do
      {:ok, _} -> IO.puts("  ✗ Should have failed!")
      {:error, reason} -> IO.puts("  ✓ Expected error for invalid email: #{inspect(reason)}")
    end
    
    # 3. Batch operations
    IO.puts("\n3. Batch variable operations:")
    
    # Get multiple variables
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_variables", %{
      names: ["user_age", "temperature", "is_active"]
    })
    IO.puts("  Batch get result:")
    Enum.each(result["variables"], fn var ->
      IO.puts("    - #{var["name"]}: #{var["value"]}")
    end)
    
    # Set multiple variables
    {:ok, result} = Snakepit.execute_in_session(session_id, "set_variables", %{
      updates: [
        %{name: "user_age", value: 35},
        %{name: "temperature", value: 22.3},
        %{name: "is_active", value: false}
      ]
    })
    IO.puts("  ✓ Batch update completed: #{length(result["updated"])} variables updated")
    
    # 4. Variable search and filtering
    IO.puts("\n4. Searching and filtering variables:")
    
    # List by pattern
    {:ok, result} = Snakepit.execute_in_session(session_id, "list_variables", %{
      pattern: "user_*"
    })
    IO.puts("  Variables matching 'user_*': #{length(result["variables"])}")
    
    # List by type
    {:ok, result} = Snakepit.execute_in_session(session_id, "list_variables", %{
      type: "integer"
    })
    IO.puts("  Integer variables: #{length(result["variables"])}")
    
    # 5. Variable metadata and history
    IO.puts("\n5. Variable metadata:")
    
    {:ok, var_info} = Snakepit.execute_in_session(session_id, "get_variable", %{
      name: "user_age",
      include_metadata: true
    })
    IO.puts("  Variable details:")
    IO.puts("    Name: #{var_info["name"]}")
    IO.puts("    Type: #{var_info["type"]}")
    IO.puts("    Value: #{var_info["value"]}")
    IO.puts("    Created: #{var_info["created_at"]}")
    IO.puts("    Updated: #{var_info["updated_at"]}")
    IO.puts("    Metadata: #{inspect(var_info["metadata"])}")
    
    # 6. Delete variables
    IO.puts("\n6. Cleaning up variables:")
    
    {:ok, _} = Snakepit.execute_in_session(session_id, "delete_variable", %{
      name: "temperature"
    })
    IO.puts("  ✓ Deleted temperature variable")
    
    # Clean up session
    {:ok, _} = Snakepit.execute_in_session(session_id, "cleanup_session", %{
      delete_all: true
    })
    IO.puts("  ✓ Session cleaned up")
  end
end

# Run the example
VariableExample.run()

# Allow time for operations to complete
Process.sleep(1000)

# Graceful shutdown
IO.puts("\nShutting down...")
Application.stop(:snakepit)