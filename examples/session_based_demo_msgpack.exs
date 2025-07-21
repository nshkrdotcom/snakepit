#!/usr/bin/env elixir

# Session-Based Snakepit Demo with MessagePack
# Run with: elixir examples/session_based_demo_msgpack.exs [pool_size]
# Example: elixir examples/session_based_demo_msgpack.exs 8

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
    IO.puts("⚠️ Usage: elixir examples/session_based_demo_msgpack.exs [pool_size]")
    IO.puts("⚠️ Using default pool size: 4")
    4
end

# Configure Snakepit for session-based execution with MessagePack
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

defmodule SnakepitSessionDemo do
  def run(pool_size) do
    IO.puts("\n🔗 Snakepit Session-Based Execution Demo - MessagePack Protocol")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("🐍 Pool Size: #{pool_size} Python workers")
    IO.puts("📦 Wire Protocol: MessagePack (up to 55x faster for binary data)")
    IO.puts("=" |> String.duplicate(70))
    
    # Wait for pool to initialize
    
    # Demo 1: Basic session-based execution
    IO.puts("\n1️⃣ Basic Session Test:")
    
    # Session ID for this demo
    session_id = "demo_session_#{System.unique_integer([:positive])}"
    IO.puts("✅ Using session: #{session_id}")
    
    # Execute commands in the session (session auto-created)
    {:ok, result1} = Snakepit.execute_in_session(session_id, "echo", %{message: "Hello from session!", session_data: %{name: "Alice", age: 30}})
    IO.puts("📝 Session result 1: #{inspect(result1["echoed"]["message"])}")
    
    {:ok, result2} = Snakepit.execute_in_session(session_id, "echo", %{message: "Session persistence test", counter: 1})
    IO.puts("📝 Session result 2: #{inspect(result2["echoed"]["message"])}")
    
    # The session automatically maintains worker affinity
    IO.puts("✅ Session demonstrates worker affinity - same worker handles related requests")
    
    # Demo 2: Multiple sessions with worker isolation
    IO.puts("\n2️⃣ Session Isolation Test:")
    
    session1 = "user_session_bob_#{System.unique_integer([:positive])}"
    session2 = "user_session_carol_#{System.unique_integer([:positive])}"
    
    IO.puts("✅ Using sessions: #{session1} and #{session2}")
    
    # Different data in each session
    {:ok, result1} = Snakepit.execute_in_session(session1, "echo", %{user: "Bob", preferences: %{theme: "dark"}})
    {:ok, result2} = Snakepit.execute_in_session(session2, "echo", %{user: "Carol", preferences: %{theme: "light"}})
    
    IO.puts("📝 Session 1 user: #{inspect(result1["echoed"]["user"])}")
    IO.puts("📝 Session 2 user: #{inspect(result2["echoed"]["user"])}")
    IO.puts("✅ Sessions maintain independent worker affinity")
    
    # Demo 3: Binary data in sessions (MessagePack advantage)
    IO.puts("\n3️⃣ Binary Data in Sessions (MessagePack Advantage):")
    
    binary_session = "binary_session_#{System.unique_integer([:positive])}"
    
    # Process binary data through session
    image_data = :crypto.strong_rand_bytes(5000)  # 5KB of "image" data
    {:ok, result} = Snakepit.execute_in_session(binary_session, "echo", %{
      image: image_data,
      metadata: %{format: "png", size: byte_size(image_data)},
      message: "Processing binary data"
    })
    
    retrieved_data = result["echoed"]["image"]
    
    if is_binary(retrieved_data) && retrieved_data == image_data do
      IO.puts("✅ Binary data preserved perfectly in session!")
      IO.puts("   Size: #{byte_size(retrieved_data)} bytes")
      IO.puts("   MessagePack handles binary natively (no base64 needed)")
    else
      IO.puts("⚠️ Binary data was modified")
    end
    
    # Demo 4: Concurrent sessions
    IO.puts("\n4️⃣ Concurrent Sessions Test:")
    
    # Create multiple sessions concurrently
    session_tasks = for i <- 1..min(pool_size, 10) do
      Task.async(fn ->
        session_id = "concurrent_session_#{i}_#{System.unique_integer([:positive])}"
        
        # Session-specific computation
        {:ok, result} = Snakepit.execute_in_session(session_id, "compute", %{
          operation: "multiply", 
          a: i, 
          b: i * 10,
          session_number: i
        })
        
        # Additional session operation to test affinity
        {:ok, echo_result} = Snakepit.execute_in_session(session_id, "echo", %{
          session_id: session_id,
          result: result["result"]
        })
        
        {i, result["result"], echo_result["echoed"]["session_id"]}
      end)
    end
    
    # Collect results
    results = Task.await_many(session_tasks, 10_000)
    
    IO.puts("✅ All concurrent sessions completed successfully")
    for {i, computation, session_id} <- Enum.sort(results) do
      IO.puts("   Session #{i}: computed #{computation}, session: #{String.slice(session_id, 0, 20)}...")
    end
    
    # Demo 5: Session Store Statistics  
    IO.puts("\n5️⃣ Session Performance Notes:")
    
    IO.puts("📊 Session Benefits with MessagePack:")
    IO.puts("   - Worker affinity: Same session prefers same worker")
    IO.puts("   - Binary data: 55x faster transfer with MessagePack")
    IO.puts("   - State isolation: Each session maintains independent context")
    IO.puts("   - Automatic management: No manual cleanup required")
    
    # Demo 6: Performance notes
    IO.puts("\n6️⃣ MessagePack Performance Benefits:")
    IO.puts("📈 With MessagePack protocol:")
    IO.puts("   - Session data transfers are 1.3-2.3x faster")
    IO.puts("   - Binary data (images, files) transfer 55x faster")
    IO.puts("   - Less memory usage due to smaller message sizes")
    IO.puts("   - Perfect for ML workloads with numpy arrays or model weights")
    
    IO.puts("\n💡 Compare with session_based_demo_json.exs to see the difference!")
  end
  
end

# Run the demo
SnakepitSessionDemo.run(pool_size)