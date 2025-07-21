#!/usr/bin/env elixir

# Simple test to verify MessagePack bridge works

# Don't use auto negotiation - force MessagePack
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonMsgpack)
# Force JSON for now to test basic functionality
Application.put_env(:snakepit, :wire_protocol, :json)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :debug)

IO.puts("Testing MessagePack adapter with JSON protocol first...")
Process.sleep(1000)

case Snakepit.execute("ping", %{test: true}) do
  {:ok, result} ->
    IO.puts("✅ Ping successful: #{inspect(result)}")
  {:error, reason} ->
    IO.puts("❌ Ping failed: #{inspect(reason)}")
end