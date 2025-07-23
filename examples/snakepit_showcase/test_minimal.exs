#!/usr/bin/env elixir

# Minimal test
{:ok, _} = Application.ensure_all_started(:snakepit)
Process.sleep(3000)

IO.puts("\nCalling execute_stream...")

# Set up a timeout
parent = self()
Task.start(fn ->
  Process.sleep(5000)
  IO.puts("\n⏰ TIMEOUT - Sending exit signal")
  Process.exit(parent, :timeout)
end)

try do
  result = Snakepit.execute_stream("stream_progress", %{steps: 2}, fn chunk ->
    IO.puts("✅ CHUNK RECEIVED: #{inspect(chunk)}")
    :ok
  end, timeout: 10_000)
  
  IO.puts("RESULT: #{inspect(result)}")
catch
  :exit, :timeout ->
    IO.puts("❌ Test timed out")
end

# Give a moment for any final output
Process.sleep(500)