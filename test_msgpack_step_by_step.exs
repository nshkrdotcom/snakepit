#!/usr/bin/env elixir

# Step by step MessagePack test

Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

IO.puts("Testing MessagePack step by step...")
Process.sleep(1000)

# First test - just text
IO.puts("\n1. Text only test:")
case Snakepit.execute("echo", %{message: "hello"}) do
  {:ok, result} ->
    IO.puts("✅ Text echo successful")
  {:error, reason} ->
    IO.puts("❌ Text echo failed: #{inspect(reason)}")
end

# Wait a bit
Process.sleep(100)

# Second test - another text to confirm worker is still responsive
IO.puts("\n2. Second text test:")
case Snakepit.execute("echo", %{message: "world"}) do
  {:ok, result} ->
    IO.puts("✅ Second text echo successful")
  {:error, reason} ->
    IO.puts("❌ Second text echo failed: #{inspect(reason)}")
end

# Wait a bit
Process.sleep(100)

# Third test - tiny binary
IO.puts("\n3. Tiny binary test (5 bytes):")
tiny_binary = <<1, 2, 3, 4, 5>>
case Snakepit.execute("echo", %{data: tiny_binary}) do
  {:ok, result} ->
    returned = result["echoed"]["data"]
    if returned == tiny_binary do
      IO.puts("✅ Tiny binary successful")
    else
      IO.puts("❌ Tiny binary mismatch")
    end
  {:error, reason} ->
    IO.puts("❌ Tiny binary failed: #{inspect(reason)}")
end

# Wait a bit
Process.sleep(100)

# Fourth test - text after binary to see if worker is still alive
IO.puts("\n4. Text after binary test:")
case Snakepit.execute("echo", %{message: "still alive?"}) do
  {:ok, result} ->
    IO.puts("✅ Text after binary successful - worker still responsive!")
  {:error, reason} ->
    IO.puts("❌ Text after binary failed: #{inspect(reason)}")
end