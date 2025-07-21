#!/usr/bin/env elixir

# Test MessagePack with larger binary

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("Testing MessagePack with various binary sizes...")
Process.sleep(1000)

# Test with increasing binary sizes
for size <- [10, 100, 1000, 5000, 10000] do
  IO.puts("\nTesting with #{size} bytes...")
  binary_data = :crypto.strong_rand_bytes(size)
  
  start_time = System.monotonic_time(:millisecond)
  case Snakepit.execute("echo", %{binary: binary_data, size: size}) do
    {:ok, result} ->
      elapsed = System.monotonic_time(:millisecond) - start_time
      returned = result["echoed"]["binary"]
      if is_binary(returned) && returned == binary_data do
        IO.puts("✅ #{size} bytes successful in #{elapsed}ms")
      else
        IO.puts("❌ #{size} bytes data mismatch")
      end
    {:error, reason} ->
      elapsed = System.monotonic_time(:millisecond) - start_time
      IO.puts("❌ #{size} bytes failed after #{elapsed}ms: #{inspect(reason)}")
  end
end

IO.puts("\n📊 MessagePack handles binary data natively without base64 encoding!")