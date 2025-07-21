#!/usr/bin/env elixir

# Simple test for MessagePack - just ping

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("Testing MessagePack with auto negotiation...")
Process.sleep(1000)

case Snakepit.execute("ping", %{test: true}) do
  {:ok, result} ->
    IO.puts("✅ Ping successful: #{inspect(result, pretty: true)}")
  {:error, reason} ->
    IO.puts("❌ Ping failed: #{inspect(reason)}")
end

# Test with binary data  
IO.puts("\nTesting binary data...")
binary_data = :crypto.strong_rand_bytes(100)
case Snakepit.execute("echo", %{binary: binary_data}) do
  {:ok, result} ->
    returned = result["echoed"]["binary"]
    if is_binary(returned) && returned == binary_data do
      IO.puts("✅ Binary test successful!")
    else
      IO.puts("❌ Binary data mismatch")
    end
  {:error, reason} ->
    IO.puts("❌ Binary test failed: #{inspect(reason)}")
end