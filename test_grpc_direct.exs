#!/usr/bin/env elixir

Mix.install([
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Ensure we're in the right directory
File.cd!(".")

# Compile the protobuf files in order
{:ok, _} = Code.compile_file("lib/snakepit/grpc/snakepit.pb.ex")
{:ok, _} = Code.compile_file("lib/snakepit/grpc/snakepit_bridge.pb.ex")

# Start a Python gRPC server
port = 50080
script_path = "priv/python/grpc_bridge.py"

IO.puts("Starting Python gRPC server...")
port_ref = Port.open({:spawn_executable, System.find_executable("python3")}, [
  :binary,
  :exit_status,
  :stderr_to_stdout,
  args: [script_path, "--port", "#{port}", "--adapter", "snakepit_bridge.adapters.grpc_streaming.GRPCStreamingHandler"]
])

Process.sleep(2000)

# Connect and test
{:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
IO.puts("Connected to gRPC server")

request = %Snakepit.Grpc.ExecuteRequest{
  command: "ping_stream",
  args: %{"count" => "3", "interval" => "0.1"},
  timeout_ms: 10000,
  request_id: "direct_test"
}

IO.puts("\nTesting direct gRPC streaming...")
case Snakepit.Grpc.SnakepitBridge.Stub.execute_stream(channel, request) do
  {:ok, stream} ->
    IO.puts("Got stream: #{inspect(stream)}")
    
    # Try to consume it immediately
    stream
    |> Enum.each(fn
      {:ok, response} ->
        IO.puts("Received: #{inspect(response.chunk)}")
      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end)
    
    IO.puts("\n✅ Success!")
    
  {:error, reason} ->
    IO.puts("Failed: #{inspect(reason)}")
end

Port.close(port_ref)