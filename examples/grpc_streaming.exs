#!/usr/bin/env elixir

# Streaming with gRPC Example
# Demonstrates real-time streaming operations with progress tracking
# Usage: mix run --no-start examples/grpc_streaming.exs [pool_size]
# Example: mix run --no-start examples/grpc_streaming.exs 100

# Get pool size from command line argument (default: 2)
pool_size =
  case System.argv() do
    [size_str | _] -> String.to_integer(size_str)
    [] -> 2
  end

IO.puts("Starting with pool size: #{pool_size}")

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

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
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

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
    request_count = pool_size()

    IO.puts("1. Testing pool with #{request_count} concurrent commands:\n")

    # Run some concurrent requests to demonstrate pool usage
    tasks =
      for i <- 1..request_count do
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
    IO.puts("\n  Completed #{successes}/#{request_count} requests successfully")

    IO.puts("\n2. Pool statistics:")

    case Snakepit.Pool.get_stats() do
      stats when is_map(stats) ->
        worker_count = Snakepit.Pool.Registry.worker_count()

        IO.puts("  Workers: #{worker_count}")
        IO.puts("  Queued: #{stats.queued}")
        IO.puts("  Errors: #{stats.errors}")
        IO.puts("  Total requests: #{stats.requests}")
        IO.puts("  Queue timeouts: #{stats.queue_timeouts}")

      error ->
        IO.puts("  ❌ Failed to get stats: #{inspect(error)}")
    end

    IO.puts("\n✅ Pool scaling example complete\n")
    IO.puts("Note: Streaming tools like stream_progress are available; ping_stream is not.")
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
