#!/usr/bin/env elixir

# Test gRPC streaming more directly
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Application.ensure_all_started(:snakepit)

IO.puts("Connecting to Python gRPC server...")
{:ok, channel} = GRPC.Stub.connect("localhost:50053")

IO.puts("Creating request...")
request = %Snakepit.Bridge.ExecuteToolRequest{
  session_id: "test_session",
  tool_name: "stream_progress",
  parameters: %{
    "steps" => %Google.Protobuf.Any{
      type_url: "type.googleapis.com/snakepit.integer",
      value: Jason.encode!(3)
    }
  },
  stream: true
}

IO.puts("Calling ExecuteStreamingTool...")
stream = Snakepit.Bridge.BridgeService.Stub.execute_streaming_tool(channel, request)

IO.puts("Stream created: #{inspect(stream)}")

# Force evaluation
IO.puts("Forcing stream evaluation...")
case stream do
  %GRPC.Client.Stream{} = s ->
    IO.puts("Got GRPC.Client.Stream")
    # Try to manually receive
    case GRPC.Client.Stream.recv(s) do
      {:ok, enum} ->
        IO.puts("Got enum from recv: #{inspect(enum)}")
        enum |> Enum.take(3) |> Enum.each(&IO.inspect/1)
      error ->
        IO.puts("Recv error: #{inspect(error)}")
    end
    
  other ->
    IO.puts("Got other type: #{inspect(other)}")
    try do
      other |> Enum.take(3) |> Enum.each(&IO.inspect/1)
    rescue
      e -> IO.puts("Error: #{inspect(e)}")
    end
end