#!/usr/bin/env elixir

# Streaming with gRPC Example
# Demonstrates real-time streaming operations with progress tracking

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

defmodule StreamingExample do
  def run do
    IO.puts("\n=== Streaming gRPC Example ===\n")

    # 1. Stream progress demonstration
    IO.puts("1. Streaming progress updates:")

    Snakepit.execute_stream("ping_stream", %{count: 5}, fn chunk ->
      IO.puts("  Chunk received: #{inspect(chunk)}")
    end)

    IO.puts("\n2. Batch inference streaming:")

    Snakepit.execute_stream(
      "batch_inference",
      %{
        items: ["apple", "banana", "cherry", "date", "elderberry"]
      },
      fn chunk ->
        IO.puts("  Processed: #{inspect(chunk)}")
      end
    )

    IO.puts("\n✅ Streaming example complete")
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  StreamingExample.run()
end)
