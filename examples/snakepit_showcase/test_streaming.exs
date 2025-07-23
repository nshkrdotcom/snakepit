#!/usr/bin/env elixir

# Simple streaming test to debug the issue
IO.puts("Testing Snakepit streaming...")

# Ensure the application is started
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(2000)  # Give time for workers to start

IO.puts("\nAttempting to stream 5 progress updates...")

result = Snakepit.execute_stream("stream_progress", %{steps: 5}, fn chunk ->
  IO.puts("CALLBACK RECEIVED: #{inspect(chunk)}")
  :ok
end)

IO.puts("\nStream result: #{inspect(result)}")

# Keep the process alive to see all output
Process.sleep(1000)