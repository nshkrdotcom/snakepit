#!/usr/bin/env elixir

# Test streaming synchronously without Task
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(3000)

IO.puts("Testing synchronous stream consumption...")

# Get a worker
workers = GenServer.call(Snakepit.Pool, :list_workers)
[worker_id | _] = workers
IO.puts("Using worker: #{worker_id}")

# Get connection
connection = GenServer.call({:via, Registry, {Snakepit.Pool.Registry, worker_id}}, :get_connection)
IO.puts("Got connection to port: #{connection.port}")

# Call streaming directly
result = Snakepit.GRPC.Client.execute_streaming_tool(
  connection.channel,
  "test_session",
  "stream_progress", 
  %{steps: 2},
  timeout: 5000
)

IO.puts("Result: #{inspect(result)}")

case result do
  {:ok, stream} ->
    IO.puts("Got stream, consuming synchronously...")
    try do
      count = 0
      Enum.each(stream, fn chunk ->
        IO.puts("CHUNK #{count}: #{inspect(chunk)}")
        count = count + 1
      end)
      IO.puts("Stream complete!")
    rescue
      e ->
        IO.puts("Error: #{inspect(e)}")
        IO.puts("Stacktrace:")
        IO.inspect(__STACKTRACE__)
    end
    
  {:error, reason} ->
    IO.puts("Failed to get stream: #{inspect(reason)}")
end

IO.puts("Done!")