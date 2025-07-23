#!/usr/bin/env elixir

# Basic gRPC Usage Example
# Demonstrates simple request/response patterns with Snakepit's gRPC adapter

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

defmodule BasicExample do
  def run do
    IO.puts("\n=== Basic gRPC Example ===\n")
    
    # 1. Simple ping command
    IO.puts("1. Ping command:")
    case Snakepit.execute("ping", %{}) do
      {:ok, result} -> IO.inspect(result, label: "Ping result")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
    
    Process.sleep(100)
    
    # 2. Echo command with data
    IO.puts("\n2. Echo command:")
    echo_data = %{message: "Hello from gRPC!", timestamp: DateTime.utc_now()}
    case Snakepit.execute("echo", echo_data) do
      {:ok, result} -> IO.inspect(result, label: "Echo result")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
    
    Process.sleep(100)
    
    # 3. Compute command (simple calculation)
    IO.puts("\n3. Compute command:")
    case Snakepit.execute("compute", %{
      expression: "2 + 2",
      operation: "evaluate"
    }) do
      {:ok, result} -> IO.inspect(result, label: "Compute result")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
    
    Process.sleep(100)
    
    # 4. Error handling example
    IO.puts("\n4. Error handling:")
    case Snakepit.execute("invalid_command", %{}) do
      {:ok, result} -> IO.inspect(result, label: "Unexpected success")
      {:error, reason} -> IO.puts("Expected error: #{inspect(reason)}")
    end
    
    # 5. Custom timeout example
    IO.puts("\n5. Custom timeout:")
    case Snakepit.execute("slow_operation", %{delay: 100}, timeout: 5000) do
      {:ok, result} -> IO.inspect(result, label: "Slow operation result")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  BasicExample.run()
end)