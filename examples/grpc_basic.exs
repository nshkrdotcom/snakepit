#!/usr/bin/env elixir

# Basic gRPC Usage Example
# Demonstrates simple request/response patterns with Snakepit's gRPC adapter

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_size, 2)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

IO.inspect(Application.get_env(:snakepit, :enable_otlp?, false), label: "example enable otlp?")

IO.inspect(Application.get_env(:snakepit, :opentelemetry), label: "example otel config")

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

    # 3. Add command (simple calculation)
    IO.puts("\n3. Add command:")

    case Snakepit.execute("add", %{a: 2, b: 2}) do
      {:ok, result} -> IO.inspect(result, label: "Add result")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end

    Process.sleep(100)

    # 4. Get adapter info
    IO.puts("\n4. Adapter info:")

    case Snakepit.execute("adapter_info", %{}) do
      {:ok, result} -> IO.inspect(result, label: "Adapter info")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end

    # 5. Error handling example
    IO.puts("\n5. Error handling:")

    case Snakepit.execute("nonexistent_tool", %{}) do
      {:ok, result} -> IO.inspect(result, label: "Unexpected success")
      {:error, reason} -> IO.puts("Expected error: #{inspect(reason)}")
    end
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  BasicExample.run()
end)
