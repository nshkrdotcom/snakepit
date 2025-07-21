#!/usr/bin/env elixir

# Simple test to debug gRPC streaming issue
require Logger

# Configure to use gRPC adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pool_config, size: 2)

# Start the application
Application.ensure_all_started(:snakepit)

IO.puts("\n🔍 Testing gRPC Stream Consumption")
IO.puts("=" |> String.duplicate(50))

case Snakepit.execute_stream("ping_stream", %{count: 3, interval: 0.2}) do
  {:ok, stream} ->
    IO.puts("✅ Stream created successfully")
    IO.puts("Stream type: #{inspect(stream.__struct__)}")
    
    # Try to take just one element to see if it works
    IO.puts("\n📥 Attempting to take first element...")
    
    try do
      first = stream |> Enum.take(1)
      IO.puts("✅ First element: #{inspect(first)}")
    rescue
      e ->
        IO.puts("❌ Error taking first element: #{inspect(e)}")
        IO.puts("Stacktrace:")
        Exception.format_stacktrace(__STACKTRACE__) |> IO.puts()
    end
    
    # Try with Stream.take instead
    IO.puts("\n📥 Attempting Stream.take...")
    try do
      taken_stream = stream |> Stream.take(1) |> Enum.to_list()
      IO.puts("✅ Stream.take result: #{inspect(taken_stream)}")
    rescue
      e ->
        IO.puts("❌ Error with Stream.take: #{inspect(e)}")
    end
    
    # Try raw iteration
    IO.puts("\n📥 Attempting raw iteration...")
    try do
      stream |> Enum.each(fn chunk ->
        IO.puts("Chunk: #{inspect(chunk)}")
      end)
    rescue
      e ->
        IO.puts("❌ Error with raw iteration: #{inspect(e)}")
        IO.puts("Stacktrace:")
        Exception.format_stacktrace(__STACKTRACE__) |> IO.puts()
    end
    
  {:error, reason} ->
    IO.puts("❌ Failed to create stream: #{inspect(reason)}")
end

IO.puts("\n✅ Test complete")