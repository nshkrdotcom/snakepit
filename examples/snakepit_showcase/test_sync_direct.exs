#!/usr/bin/env elixir

# Test streaming more directly
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(3000)

IO.puts("\nTesting direct streaming without wrapper...")

# Call through the normal API but synchronously
try do
  chunks = []
  result = Snakepit.execute_stream("stream_progress", %{steps: 2}, fn chunk ->
    IO.puts("RECEIVED CHUNK: #{inspect(chunk)}")
    chunks = [chunk | chunks]
  end, timeout: 10_000)
  
  IO.puts("\nResult: #{inspect(result)}")
  IO.puts("Total chunks received: #{length(chunks)}")
catch
  :exit, reason ->
    IO.puts("Exit: #{inspect(reason)}")
  kind, error ->
    IO.puts("Error #{kind}: #{inspect(error)}")
end

# Check Python log
IO.puts("\n--- Python log ---")
case File.read("/tmp/grpc_streaming_debug.log") do
  {:ok, content} -> IO.puts(content)
  _ -> IO.puts("No Python log")
end