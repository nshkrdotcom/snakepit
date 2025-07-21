#!/usr/bin/env elixir

# Debug MessagePack issue

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonMsgpack)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :debug)

IO.puts("Testing MessagePack with debug logging...")
Process.sleep(1000)

# First just test without binary
case Snakepit.execute("echo", %{message: "hello"}) do
  {:ok, result} ->
    IO.puts("✅ Text echo successful: #{inspect(result["echoed"]["message"])}")
  {:error, reason} ->
    IO.puts("❌ Text echo failed: #{inspect(reason)}")
end

# Now test with small binary
IO.puts("\nTesting with small binary...")
small_binary = <<1, 2, 3, 4, 5>>
case Snakepit.execute("echo", %{small_binary: small_binary}) do
  {:ok, result} ->
    returned = result["echoed"]["small_binary"]
    if returned == small_binary do
      IO.puts("✅ Small binary test successful!")
    else
      IO.puts("❌ Small binary mismatch: #{inspect(returned)} vs #{inspect(small_binary)}")
    end
  {:error, reason} ->
    IO.puts("❌ Small binary test failed: #{inspect(reason)}")
end