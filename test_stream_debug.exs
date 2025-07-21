#!/usr/bin/env elixir

# Configure to use gRPC adapter
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pool_config, size: 1)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.8"},
  {:protobuf, "~> 0.12"}
])

# Test stream enumeration directly
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(3000)

IO.puts("\n🔍 Testing Stream Enumeration")

case Snakepit.execute_stream("ping_stream", %{count: 3, interval: 0.1}) do
  {:ok, stream} ->
    IO.puts("Got stream: #{inspect(stream)}")
    
    # Try different ways to enumerate
    IO.puts("\n1. Testing with Enum.to_list...")
    try do
      list = stream |> Enum.take(1)
      IO.puts("Success! Got: #{inspect(list)}")
    rescue
      e -> IO.puts("Failed: #{inspect(e)}")
    end
    
    IO.puts("\n2. Testing with Stream.run...")
    try do
      stream |> Stream.each(&IO.inspect/1) |> Stream.run()
      IO.puts("Success!")
    rescue
      e -> IO.puts("Failed: #{inspect(e)}")
    end
    
  {:error, reason} ->
    IO.puts("Failed to create stream: #{inspect(reason)}")
end