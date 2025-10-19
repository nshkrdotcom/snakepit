#!/usr/bin/env elixir

# Streaming with gRPC Example
# Demonstrates real-time streaming operations with progress tracking
# Usage: elixir examples/grpc_streaming.exs [pool_size]
# Example: elixir examples/grpc_streaming.exs 100

# Get pool size from command line argument (default: 2)
pool_size =
  case System.argv() do
    [size_str | _] -> String.to_integer(size_str)
    [] -> 2
  end

IO.puts("Starting with pool size: #{pool_size}")

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: pool_size})

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: pool_size,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :grpc_port, 50051)

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Runtime logger filtering - suppress gRPC interceptor logs
Logger.configure(level: :warning)

# Add a custom filter to suppress gRPC logs at runtime
:logger.add_primary_filter(
  :ignore_grpc,
  {fn log_event, _extra ->
     case log_event do
       %{meta: %{domain: [:elixir | _]}, msg: msg} ->
         msg_str = :logger.format_report(msg)
         # Filter out gRPC interceptor logs
         if String.contains?(msg_str, "Handled by") or String.contains?(msg_str, "Response :ok") do
           :stop
         else
           :ignore
         end

       _ ->
         :ignore
     end
   end, nil}
)

defmodule StreamingExample do
  def run do
    IO.puts("\n=== gRPC Pool Scaling Example ===\n")
    IO.puts("Pool initialized with #{pool_size()} workers\n")

    # Test basic commands with the pool
    IO.puts("1. Testing pool with basic commands:\n")

    # Run some concurrent requests to demonstrate pool usage
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          case Snakepit.execute("ping", %{}) do
            {:ok, result} ->
              IO.puts("  ✅ Request #{i}: #{inspect(result["message"])}")
              :ok

            {:error, reason} ->
              IO.puts("  ❌ Request #{i} failed: #{inspect(reason)}")
              :error
          end
        end)
      end

    results = Task.await_many(tasks, 30_000)
    successes = Enum.count(results, &(&1 == :ok))
    IO.puts("\n  Completed #{successes}/10 requests successfully")

    IO.puts("\n2. Pool statistics:")

    case Snakepit.Pool.get_stats() do
      stats when is_map(stats) ->
        IO.puts("  Workers: #{stats.workers}")
        IO.puts("  Available: #{stats.available}")
        IO.puts("  Busy: #{stats.busy}")
        IO.puts("  Total requests: #{stats.requests}")

      error ->
        IO.puts("  ❌ Failed to get stats: #{inspect(error)}")
    end

    IO.puts("\n✅ Pool scaling example complete\n")
    IO.puts("Note: Streaming tools (ping_stream, batch_inference) are not yet implemented.")
    IO.puts("This example demonstrates pool initialization and basic concurrent execution.\n")
  end

  defp pool_size do
    case System.argv() do
      [size_str | _] -> String.to_integer(size_str)
      [] -> 2
    end
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  StreamingExample.run()
end)
