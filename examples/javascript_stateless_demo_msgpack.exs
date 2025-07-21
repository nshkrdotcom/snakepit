#!/usr/bin/env elixir

# JavaScript Stateless Demo with MessagePack
# Run with: elixir examples/javascript_stateless_demo_msgpack.exs

# Note: MessagePack protocol is only available for Python bridges currently.
# This example shows how JavaScript adapter still works but falls back to JSON.

# Configure Snakepit
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)
# Request MessagePack (will fallback to JSON for JavaScript)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule JavaScriptStatelessDemo do
  def run do
    IO.puts("\n🟨 Snakepit JavaScript Stateless Demo - MessagePack Requested")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("📦 Wire Protocol: MessagePack requested (will fallback to JSON)")
    IO.puts("ℹ️  Note: JavaScript bridge currently only supports JSON protocol")
    IO.puts("=" |> String.duplicate(70))
    
    # Wait for pool to initialize
    
    # Demo 1: Basic ping
    IO.puts("\n1️⃣ Basic Ping Test:")
    case Snakepit.execute("ping", %{}) do
      {:ok, result} ->
        IO.puts("✅ Ping successful: #{inspect(result, pretty: true)}")
        IO.puts("ℹ️  Protocol used: JSON (JavaScript bridge limitation)")
      {:error, reason} ->
        IO.puts("❌ Ping failed: #{inspect(reason)}")
    end
    
    # Demo 2: Echo operation
    IO.puts("\n2️⃣ Echo Operation:")
    
    case Snakepit.execute("echo", %{
      message: "Hello from Node.js!",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      math: 42 * 3.14
    }) do
      {:ok, result} ->
        IO.puts("✅ Echo result: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Echo failed: #{inspect(reason)}")
    end
    
    # Demo 3: Compute functionality
    IO.puts("\n3️⃣ Compute Operations:")
    case Snakepit.execute("compute", %{
      operation: "multiply",
      a: 42,
      b: 3.14
    }) do
      {:ok, result} ->
        IO.puts("✅ Compute multiply result: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Compute operation failed: #{inspect(reason)}")
    end
    
    # Demo 4: System info
    IO.puts("\n4️⃣ System Information:")
    case Snakepit.execute("info", %{}) do
      {:ok, result} ->
        IO.puts("✅ System info: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Info failed: #{inspect(reason)}")
    end
    
    # Demo 5: Performance comparison note
    IO.puts("\n5️⃣ Protocol Performance Notes:")
    IO.puts("📊 JavaScript bridge currently uses JSON protocol")
    IO.puts("   - MessagePack support could be added to JavaScript bridge")
    IO.puts("   - Would require implementing MessagePack in generic_bridge.js")
    IO.puts("   - Python bridges get 1.3-55x speedup with MessagePack")
    IO.puts("\n💡 For MessagePack benefits, use Python-based adapters!")
    
    # Show pool stats
    IO.puts("\n📊 Pool Statistics:")
    stats = Snakepit.Pool.get_stats()
    IO.puts("   Requests: #{stats.requests}")
    IO.puts("   Errors: #{stats.errors}")
  end
end

# Run the demo
JavaScriptStatelessDemo.run()