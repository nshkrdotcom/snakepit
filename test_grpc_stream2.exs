#!/usr/bin/env elixir

# Ensure we start fresh
Application.stop(:snakepit)

# Configure to use gRPC adapter BEFORE starting
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pool_config, size: 1)

# Simple test to debug gRPC streaming issue
require Logger

# Now start the application with gRPC config
{:ok, _} = Application.ensure_all_started(:snakepit)

# Wait for pool to be ready
Process.sleep(3000)

IO.puts("\n🔍 Testing gRPC Stream Consumption")
IO.puts("=" |> String.duplicate(50))

case Snakepit.execute_stream("ping_stream", %{count: 3, interval: 0.2}) do
  {:ok, stream} ->
    IO.puts("✅ Stream created successfully")
    IO.puts("Stream inspection: #{inspect(stream, limit: :infinity)}")
    
    # Try to take just one element to see if it works
    IO.puts("\n📥 Attempting to take first element...")
    
    # The issue might be that the stream elements need special handling
    # Let's see what actually comes from the stream
    result = try do
      # Force evaluation of one element
      case Enum.take(stream, 1) do
        [] -> 
          IO.puts("❌ Stream returned empty list")
          :empty
        [first | _] -> 
          IO.puts("✅ Got first element: #{inspect(first, limit: :infinity)}")
          {:ok, first}
        other ->
          IO.puts("❓ Unexpected result: #{inspect(other)}")
          {:unexpected, other}
      end
    rescue
      e ->
        IO.puts("❌ Exception during Enum.take: #{inspect(e)}")
        IO.puts("Exception message: #{Exception.message(e)}")
        {:error, e}
    catch
      kind, value ->
        IO.puts("❌ Caught #{kind}: #{inspect(value)}")
        {:caught, kind, value}
    end
    
    IO.puts("\nResult: #{inspect(result)}")
    
  {:error, reason} ->
    IO.puts("❌ Failed to create stream: #{inspect(reason)}")
end

IO.puts("\n✅ Test complete")