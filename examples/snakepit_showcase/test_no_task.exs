# Test without Task.async
IO.puts("Testing stream without Task.async...")

{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, channel} = GRPC.Stub.connect("localhost:50111")

request = %Snakepit.Bridge.ExecuteToolRequest{
  session_id: "test",
  tool_name: "stream_progress",
  parameters: %{
    "steps" => %Google.Protobuf.Any{
      type_url: "type.googleapis.com/snakepit.integer",
      value: Jason.encode!(3)
    }
  },
  stream: true
}

{:ok, stream} = Snakepit.Bridge.BridgeService.Stub.execute_streaming_tool(channel, request)

IO.puts("Got stream, consuming without Task...")

# Direct consumption without Task
try do
  Enum.each(stream, fn chunk ->
    IO.puts("CHUNK: #{inspect(chunk)}")
  end)
  IO.puts("Stream complete!")
rescue
  e ->
    IO.puts("Error: #{inspect(e)}")
end

IO.puts("\n--- Python log ---")
File.read!("/tmp/grpc_streaming_debug.log") |> IO.puts()