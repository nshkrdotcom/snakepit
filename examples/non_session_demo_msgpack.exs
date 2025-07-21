#!/usr/bin/env elixir

# Non-Session-Based Snakepit Demo with MessagePack
# Run with: elixir examples/non_session_demo_msgpack.exs [pool_size]
# Example: elixir examples/non_session_demo_msgpack.exs 8

# Parse command line arguments
pool_size = case System.argv() do
  [size_str] ->
    case Integer.parse(size_str) do
      {size, ""} when size > 0 and size <= 200 ->
        IO.puts("🔧 Using pool size: #{size}")
        size
      {size, ""} when size > 200 ->
        IO.puts("⚠️ Pool size #{size} exceeds maximum of 200, using 200")
        200
      {size, ""} when size <= 0 ->
        IO.puts("⚠️ Pool size must be positive, using default: 4")
        4
      _ ->
        IO.puts("⚠️ Invalid pool size '#{size_str}', using default: 4")
        4
    end
  [] ->
    IO.puts("🔧 Using default pool size: 4")
    4
  _ ->
    IO.puts("⚠️ Usage: elixir examples/non_session_demo_msgpack.exs [pool_size]")
    IO.puts("⚠️ Using default pool size: 4")
    4
end

# Configure Snakepit for stateless execution with MessagePack
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: pool_size
})
# Use the V2 adapter with auto-negotiation (will prefer MessagePack for this demo)
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)
Application.put_env(:snakepit, :wire_protocol, :auto)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitStatelessDemo do
  def run(pool_size) do
    IO.puts("\n⚡ Snakepit Non-Session (Stateless) Execution Demo - MessagePack Protocol")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("🐍 Pool Size: #{pool_size} Python workers")
    IO.puts("📦 Wire Protocol: MessagePack (up to 55x faster for binary data)")
    IO.puts("=" |> String.duplicate(70))
    
    # Wait for pool to initialize
    
    # Demo 1: Basic ping
    IO.puts("\n1️⃣ Basic Ping Test:")
    case Snakepit.execute("ping", %{test: true}) do
      {:ok, result} ->
        IO.puts("✅ Ping successful: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Ping failed: #{inspect(reason)}")
    end
    
    # Demo 2: Echo test
    IO.puts("\n2️⃣ Echo Test:")
    echo_data = %{
      message: "Hello from Elixir with MessagePack!",
      numbers: [1, 2, 3, 4, 5],
      nested: %{key: "value", flag: true}
    }
    case Snakepit.execute("echo", echo_data) do
      {:ok, result} ->
        IO.puts("✅ Echo successful: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Echo failed: #{inspect(reason)}")
    end
    
    # Demo 3: Computation
    IO.puts("\n3️⃣ Computation Test:")
    case Snakepit.execute("compute", %{operation: "multiply", a: 42, b: 3.14}) do
      {:ok, result} ->
        IO.puts("✅ Compute successful: #{inspect(result, pretty: true)}")
      {:error, reason} ->
        IO.puts("❌ Compute failed: #{inspect(reason)}")
    end
    
    # Demo 4: Binary data test (showcasing MessagePack efficiency)
    IO.puts("\n4️⃣ Binary Data Test (MessagePack Advantage):")
    binary_data = :crypto.strong_rand_bytes(1024)  # 1KB of random data
    case Snakepit.execute("echo", %{binary: binary_data, size: byte_size(binary_data)}) do
      {:ok, result} ->
        returned_binary = result["echoed"]["binary"]
        if is_binary(returned_binary) && returned_binary == binary_data do
          IO.puts("✅ Binary data round-trip successful! Size: #{byte_size(returned_binary)} bytes")
          IO.puts("   MessagePack handles binary data natively (no base64 encoding needed)")
        else
          IO.puts("⚠️ Binary data changed during round-trip")
        end
      {:error, reason} ->
        IO.puts("❌ Binary test failed: #{inspect(reason)}")
    end
    
    # Demo 5: Concurrent requests
    IO.puts("\n5️⃣ Concurrent Requests Test (Pool Size: #{pool_size}):")
    
    # Start timing
    start_time = System.monotonic_time(:millisecond)
    
    # Launch concurrent tasks
    tasks = for i <- 1..pool_size do
      Task.async(fn ->
        case Snakepit.execute("compute", %{operation: "add", a: i, b: i * 10}) do
          {:ok, result} -> {:ok, i, result["result"]}
          {:error, reason} -> {:error, i, reason}
        end
      end)
    end
    
    # Collect results
    results = Task.await_many(tasks, 10_000)
    
    # Calculate timing
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    # Display results
    successful = Enum.filter(results, fn {status, _, _} -> status == :ok end)
    failed = Enum.filter(results, fn {status, _, _} -> status == :error end)
    
    IO.puts("✅ Successful: #{length(successful)}/#{pool_size}")
    IO.puts("❌ Failed: #{length(failed)}/#{pool_size}")
    IO.puts("⏱️ Total time: #{elapsed}ms")
    IO.puts("📊 Average per request: #{Float.round(elapsed / pool_size, 2)}ms")
    
    # Demo 6: Performance comparison hint
    IO.puts("\n6️⃣ Performance Notes:")
    IO.puts("📈 MessagePack provides:")
    IO.puts("   - 1.3-2.3x faster encoding/decoding for regular data")
    IO.puts("   - 55x faster for binary data (no base64 encoding)")
    IO.puts("   - 18-36% smaller message sizes")
    IO.puts("\n💡 Compare with non_session_demo_json.exs to see the difference!")
    
    # Show pool stats
    IO.puts("\n📊 Pool Statistics:")
    stats = Snakepit.Pool.get_stats()
    IO.puts("   Requests: #{stats.requests}")
    IO.puts("   Errors: #{stats.errors}")
    IO.puts("   Queue timeouts: #{stats.queue_timeouts}")
  end
end

# Run the demo
SnakepitStatelessDemo.run(pool_size)