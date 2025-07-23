#!/usr/bin/env elixir

# Session Management with gRPC Example
# Demonstrates stateful operations with session affinity

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

defmodule SessionExample do
  def run do
    IO.puts("\n=== Session Management Example ===\n")
    
    # Create a unique session ID
    session_id = "demo_session_#{System.unique_integer([:positive])}"
    IO.puts("Session ID: #{session_id}")
    
    # 1. Initialize session
    IO.puts("\n1. Initializing session:")
    {:ok, _} = Snakepit.execute_in_session(session_id, "initialize_session", %{
      config: %{
        cache_enabled: true,
        telemetry_enabled: false
      }
    })
    IO.puts("Session initialized")
    
    # 2. Register a variable in the session
    IO.puts("\n2. Registering variable in session:")
    {:ok, result} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "counter",
      type: "integer",
      initial_value: 0,
      constraints: %{min: 0, max: 100}
    })
    IO.inspect(result, label: "Variable registered")
    
    # 3. Update the variable multiple times
    IO.puts("\n3. Updating variable in session:")
    for i <- 1..5 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "set_variable", %{
        name: "counter",
        value: i * 10
      })
      IO.puts("Counter updated to: #{result["value"]}")
      Process.sleep(100)
    end
    
    # 4. Retrieve variable from session
    IO.puts("\n4. Retrieving variable from session:")
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_variable", %{
      name: "counter"
    })
    IO.inspect(result, label: "Current counter value")
    
    # 5. Store computation result in session
    IO.puts("\n5. Storing computation result:")
    {:ok, _} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "computation_result",
      type: "string",
      initial_value: ""
    })
    
    {:ok, _} = Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "computation_result",
      value: "Processed #{result["value"]} items"
    })
    
    # 6. List all variables in session
    IO.puts("\n6. Listing all session variables:")
    {:ok, variables} = Snakepit.execute_in_session(session_id, "list_variables", %{})
    Enum.each(variables["variables"], fn var ->
      IO.puts("  - #{var["name"]} (#{var["type"]}): #{inspect(var["value"])}")
    end)
    
    # 7. Demonstrate session affinity
    IO.puts("\n7. Session affinity check:")
    worker_ids = for _ <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{})
      result["worker_id"] || "unknown"
    end
    IO.puts("Worker IDs for session calls: #{inspect(worker_ids)}")
    IO.puts("(Should prefer the same worker when possible)")
    
    # 8. Clean up session
    IO.puts("\n8. Cleaning up session:")
    {:ok, _} = Snakepit.execute_in_session(session_id, "cleanup_session", %{
      delete_all: true
    })
    IO.puts("Session cleaned up")
  end
end

# Run the example
SessionExample.run()

# Allow time for operations to complete
Process.sleep(1000)

# Graceful shutdown
IO.puts("\nShutting down...")
Application.stop(:snakepit)