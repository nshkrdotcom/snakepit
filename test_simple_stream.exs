#!/usr/bin/env elixir

# Simple test to see if streaming works at all
require Logger

# Create a simple stream and see if it can be consumed
test_stream = Stream.unfold(0, fn
  5 -> nil
  n -> {n, n + 1}
end)

IO.puts("Testing basic Stream.unfold consumption:")
test_stream |> Enum.take(3) |> IO.inspect()

# Now test with the same pattern as gRPC uses
wrapped_stream = Stream.map(test_stream, fn x -> {:ok, x} end)
IO.puts("\nTesting wrapped stream:")
wrapped_stream |> Enum.take(3) |> IO.inspect()

# Test the exact pattern from the logs
stream_from_log = Stream.unfold(0, fn _ -> nil end)
IO.puts("\nTesting empty stream like gRPC might return:")
result = stream_from_log |> Enum.take(1)
IO.puts("Result: #{inspect(result)}")

IO.puts("\nDone!")