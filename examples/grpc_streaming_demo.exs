#!/usr/bin/env elixir

# gRPC Streaming Demo for Snakepit
# Demonstrates real-time streaming with the ShowcaseAdapter
# Usage: elixir examples/grpc_streaming_demo.exs [pool_size]

pool_size =
  case System.argv() do
    [size_str] ->
      case Integer.parse(size_str) do
        {size, ""} when size > 0 -> size
        _ -> 2
      end

    [] ->
      2

    _ ->
      2
  end

# Configure Snakepit
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: pool_size})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_port, 50051)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

defmodule StreamingDemo do
  def run(pool_size) do
    IO.puts("\n🚀 Snakepit gRPC Streaming Demo")
    IO.puts("=" |> String.duplicate(50))
    IO.puts("🐍 Pool Size: #{pool_size} workers")
    IO.puts("")

    # Demo 1: Progress streaming
    IO.puts("📊 Demo 1: Progress Updates")
    IO.puts("-" |> String.duplicate(40))

    {:ok, _} =
      Snakepit.execute_stream("ping_stream", %{count: 5}, fn chunk ->
        IO.puts("  #{inspect(chunk)}")
      end)

    IO.puts("")

    # Demo 2: Batch processing
    IO.puts("🔄 Demo 2: Batch Processing")
    IO.puts("-" |> String.duplicate(40))

    items = ["apple", "banana", "cherry", "date", "elderberry"]

    {:ok, _} =
      Snakepit.execute_stream("batch_inference", %{items: items}, fn chunk ->
        IO.puts("  Processed: #{inspect(chunk)}")
      end)

    IO.puts("")

    # Demo 3: Multiple concurrent streams
    IO.puts("⚡ Demo 3: Concurrent Streams")
    IO.puts("-" |> String.duplicate(40))

    tasks =
      for i <- 1..3 do
        Task.async(fn ->
          result_count = :atomics.new(1, [])

          {:ok, _} =
            Snakepit.execute_stream("ping_stream", %{count: 3}, fn _chunk ->
              :atomics.add(result_count, 1, 1)
            end)

          :atomics.get(result_count, 1)
        end)
      end

    results = Task.await_many(tasks, 30_000)
    IO.puts("  Received chunks: #{inspect(results)}")
    IO.puts("  Total: #{Enum.sum(results)} chunks from #{length(tasks)} concurrent streams")

    IO.puts("")
    IO.puts("✅ Streaming demo complete!")
  end
end

# Run with proper cleanup
Snakepit.run_as_script(fn ->
  StreamingDemo.run(pool_size)
end)
