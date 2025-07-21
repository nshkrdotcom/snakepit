#!/usr/bin/env elixir

# Test with 1KB binary like in the example

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :debug)

IO.puts("Testing 1KB binary with MessagePack...")
Process.sleep(1000)

# Test exactly like in the example
binary_data = :crypto.strong_rand_bytes(1024)  # 1KB of random data
IO.puts("Binary size: #{byte_size(binary_data)} bytes")

case Snakepit.execute("echo", %{binary: binary_data, size: byte_size(binary_data)}) do
  {:ok, result} ->
    IO.puts("Result keys: #{inspect(Map.keys(result))}")
    returned_binary = result["echoed"]["binary"]
    if is_binary(returned_binary) && returned_binary == binary_data do
      IO.puts("✅ Binary data round-trip successful!")
    else
      IO.puts("⚠️ Binary data changed during round-trip")
      IO.puts("Returned type: #{inspect(returned_binary)}")
    end
  {:error, reason} ->
    IO.puts("❌ Binary test failed: #{inspect(reason)}")
end