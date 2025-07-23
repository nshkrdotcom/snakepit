#!/usr/bin/env elixir

# Direct test bypassing the normal flow
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(3000)

IO.puts("Getting a worker connection...")

# Get connection directly from a worker
worker_id = "pool_worker_1_6402"  # Will need to adjust based on actual worker ID
connection = GenServer.call({:via, Registry, {Snakepit.Pool.Registry, worker_id}}, :get_connection)

IO.puts("Connection: #{inspect(connection)}")

# Call the streaming function directly
result = Snakepit.GRPC.Client.execute_streaming_tool(
  connection.channel,
  "default_session", 
  "stream_progress",
  %{steps: 2},
  timeout: 5000
)

IO.puts("Stream result: #{inspect(result)}")

case result do
  {:ok, stream} ->
    IO.puts("Got stream, trying to consume...")
    try do
      stream
      |> Stream.take(5)
      |> Enum.each(fn chunk ->
        IO.puts("CHUNK: #{inspect(chunk)}")
      end)
    rescue
      e ->
        IO.puts("Error consuming stream: #{inspect(e)}")
    end
    
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end