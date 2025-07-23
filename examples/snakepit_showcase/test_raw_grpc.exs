# Raw gRPC test
IO.puts("Starting raw gRPC test...")

# Minimal startup
{:ok, _} = Application.ensure_all_started(:grpc)

# Connect directly
IO.puts("Connecting to localhost:50111...")
{:ok, channel} = GRPC.Stub.connect("localhost:50111")

# Create request
request = %Snakepit.Bridge.ExecuteToolRequest{
  session_id: "test",
  tool_name: "stream_progress",
  parameters: %{
    "steps" => %Google.Protobuf.Any{
      type_url: "type.googleapis.com/snakepit.integer",
      value: Jason.encode!(2)
    }
  },
  stream: true
}

IO.puts("Sending ExecuteStreamingTool request...")

# Call the streaming RPC
result = Snakepit.Bridge.BridgeService.Stub.execute_streaming_tool(channel, request)

IO.puts("Got result: #{inspect(result)}")

# Try to consume
case result do
  {:ok, stream} ->
    IO.puts("Stream type: #{inspect(stream)}")
    
    # Try different consumption methods
    IO.puts("\nTrying Enum.take...")
    try do
      items = stream |> Enum.take(1)
      IO.puts("Got items: #{inspect(items)}")
    rescue
      e -> IO.puts("Take failed: #{inspect(e)}")
    catch
      kind, error -> IO.puts("Take error #{kind}: #{inspect(error)}")
    end
    
  error ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("\n--- Python log ---")
case File.read("/tmp/grpc_streaming_debug.log") do
  {:ok, content} -> IO.puts(content)
  _ -> IO.puts("No log")
end