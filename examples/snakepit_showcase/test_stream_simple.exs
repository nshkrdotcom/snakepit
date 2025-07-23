#!/usr/bin/env elixir

IO.puts("Starting test...")

# Start the app
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(2000)

IO.puts("Calling Snakepit.execute_stream...")

# Use spawn to run in background and timeout
task = Task.async(fn ->
  Snakepit.execute_stream("stream_progress", %{steps: 3}, fn chunk ->
    IO.puts("CHUNK: #{inspect(chunk)}")
  end)
end)

# Wait up to 10 seconds
case Task.yield(task, 10_000) || Task.shutdown(task) do
  {:ok, result} ->
    IO.puts("Result: #{inspect(result)}")
  nil ->
    IO.puts("Task timed out after 10 seconds")
  {:exit, reason} ->
    IO.puts("Task exited: #{inspect(reason)}")
end

IO.puts("Test complete")