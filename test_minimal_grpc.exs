#!/usr/bin/env elixir

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.8"},
  {:protobuf, "~> 0.12"}
])

require Logger
Logger.configure(level: :info)

# Ensure modules are compiled
Code.compile_file("lib/snakepit/grpc/snakepit.pb.ex")
Code.compile_file("lib/snakepit/grpc/snakepit_bridge.pb.ex")

# Start a Python gRPC server directly
port = 50070
script_path = Path.join([Application.app_dir(:snakepit), "priv", "python", "grpc_bridge.py"])

IO.puts("Starting Python gRPC server on port #{port}...")
port_ref = Port.open({:spawn_executable, System.find_executable("python3")}, [
  :binary,
  :exit_status,
  :stderr_to_stdout,
  args: [script_path, "--port", "#{port}", "--adapter", "snakepit_bridge.adapters.grpc_streaming.GRPCStreamingHandler"]
])

Process.sleep(2000)

IO.puts("Connecting to gRPC server...")
{:ok, channel} = GRPC.Stub.connect("localhost:#{port}")

request = %Snakepit.Grpc.ExecuteRequest{
  command: "ping_stream",
  args: %{
    "count" => Jason.encode!(3),
    "interval" => Jason.encode!(0.5)  # Add back interval to slow down the stream
  },
  timeout_ms: 10000,
  request_id: "test_minimal"
}

IO.puts("Calling execute_stream...")
case Snakepit.Grpc.SnakepitBridge.Stub.execute_stream(channel, request) do
  {:ok, stream} ->
    IO.puts("Got stream, consuming...")
    
    try do
      stream
      |> Enum.each(fn
        {:ok, response} ->
          IO.puts("Received: #{inspect(response.chunk)}")
        {:error, error} ->
          IO.puts("Error: #{inspect(error)}")
        other ->
          IO.puts("Unexpected: #{inspect(other)}")
      end)
      IO.puts("✅ Stream consumed successfully!")
    rescue
      e ->
        IO.puts("❌ Error: #{inspect(e)}")
        IO.puts(Exception.format_stacktrace(__STACKTRACE__))
    end
    
  {:error, reason} ->
    IO.puts("Failed to create stream: #{inspect(reason)}")
end

Port.close(port_ref)