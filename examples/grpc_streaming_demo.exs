#!/usr/bin/env elixir

# gRPC Streaming Demo for Snakepit
# Demonstrates real-time streaming with the ShowcaseAdapter
# Usage: mix run --no-start examples/grpc_streaming_demo.exs [pool_size]

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

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Configure Snakepit
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_size, pool_size)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: pool_size,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: pool_size})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :grpc_port, 50051)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

defmodule StreamingDemo do
  def run(pool_size) do
    IO.puts("\n🚀 Snakepit gRPC Streaming Demo")
    IO.puts("=" |> String.duplicate(50))
    IO.puts("🐍 Pool Size: #{pool_size} workers")
    IO.puts("")

    # Demo 1: Progress streaming
    IO.puts("📊 Demo 1: Progress Updates")
    IO.puts("-" |> String.duplicate(40))

    case Snakepit.execute_stream("stream_progress", %{steps: 5, delay_ms: 150}, fn chunk ->
           IO.puts("  #{inspect(chunk)}")
         end) do
      :ok -> IO.puts("  ✅ Streaming completed")
      {:ok, _} -> IO.puts("  ✅ Streaming completed")
      {:error, reason} -> IO.puts("  ⚠️  Streaming error: #{inspect(reason)}")
    end

    IO.puts("")

    # Demo 2: Simple echo demonstration (non-streaming)
    IO.puts("🔄 Demo 2: Simple Operations")
    IO.puts("-" |> String.duplicate(40))

    items = ["apple", "banana", "cherry", "date", "elderberry"]

    results =
      Enum.map(items, fn item ->
        {:ok, result} = Snakepit.execute("echo", %{item: item})
        IO.puts("  Processed: #{item}")
        result
      end)

    IO.puts("  ✅ Processed #{length(results)} items")

    IO.puts("")

    # Demo 3: Concurrent operations
    IO.puts("⚡ Demo 3: Concurrent Operations")
    IO.puts("-" |> String.duplicate(40))

    tasks =
      for _i <- 1..3 do
        Task.async(fn ->
          {:ok, result} = Snakepit.execute("ping", %{})
          result
        end)
      end

    results = Task.await_many(tasks, 30_000)
    IO.puts("  Completed: #{length(results)} concurrent operations")

    IO.puts("")
    IO.puts("✅ Demo complete!")
  end
end

# Run with proper cleanup
Snakepit.Examples.Bootstrap.run_example(fn ->
  StreamingDemo.run(pool_size)
end)
