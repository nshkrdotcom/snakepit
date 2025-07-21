#!/usr/bin/env elixir

# Test JSON with binary to compare

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2
Application.put_env(:snakepit, :wire_protocol, :json)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("Testing JSON with binary data...")
Process.sleep(1000)

# Test with small binary
binary_data = :crypto.strong_rand_bytes(10)
case Snakepit.execute("echo", %{binary: binary_data}) do
  {:ok, result} ->
    returned = result["echoed"]["binary"]
    IO.puts("Returned type: #{inspect(is_binary(returned))}")
    IO.puts("Returned value: #{inspect(returned)}")
    if returned == binary_data do
      IO.puts("✅ Binary test successful!")
    else
      IO.puts("❌ Binary data mismatch")
    end
  {:error, reason} ->
    IO.puts("❌ Binary test failed: #{inspect(reason)}")
end