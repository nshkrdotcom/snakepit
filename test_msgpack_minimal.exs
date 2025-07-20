#!/usr/bin/env elixir

# Minimal MessagePack test

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonMsgpack)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("Minimal MessagePack test...")
Process.sleep(1000)

# Just test ping
case Snakepit.execute("ping", %{test: true}) do
  {:ok, result} ->
    IO.puts("✅ Ping successful")
  {:error, reason} ->
    IO.puts("❌ Ping failed: #{inspect(reason)}")
end

Process.sleep(500)

# Test echo with small binary
small_binary = <<1, 2, 3>>
case Snakepit.execute("echo", %{small: small_binary}) do
  {:ok, result} ->
    returned = result["echoed"]["small"]
    if returned == small_binary do
      IO.puts("✅ Small binary successful")
    else
      IO.puts("❌ Small binary mismatch: #{inspect(returned)}")
    end
  {:error, reason} ->
    IO.puts("❌ Small binary failed: #{inspect(reason)}")
end

Process.sleep(500)

IO.puts("Test complete")