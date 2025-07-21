#!/usr/bin/env elixir

# Session-Based Snakepit Demo
# Run with: elixir examples/session_based_demo.exs [pool_size]
# Example: elixir examples/session_based_demo.exs 8

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
    IO.puts("⚠️ Usage: elixir examples/session_based_demo.exs [pool_size]")
    IO.puts("⚠️ Using default pool size: 4")
    4
end

# Configure Snakepit for session-based execution
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: pool_size
})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPythonV2)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitSessionDemo do
  def run(pool_size) do
    IO.puts("\n🔗 Snakepit Session-Based Execution Demo")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("🐍 Pool Size: #{pool_size} Python workers")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Check if pool is running
    pool_pid = Process.whereis(Snakepit.Pool)

    if pool_pid do
      IO.puts("\n✅ Pool started successfully: #{inspect(pool_pid)}")
      
      # Test session-based execution
      test_session_creation()
      test_session_state_persistence()
      test_session_data_accumulation()
      test_session_cleanup()
      show_pool_stats()
      
      IO.puts("\n🎯 All session tests completed!")
    else
      IO.puts("\n❌ Pool not found! Check configuration.")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp test_session_creation do
    IO.puts("\n📝 Testing session creation and initialization...")
    
    session_id = "demo_session_#{System.os_time(:millisecond)}"
    
    # Initialize session with some state
    case Snakepit.execute_in_session(session_id, "echo", %{
      action: "initialize_session",
      session_data: %{counter: 0, items: []}
    }) do
      {:ok, result} ->
        IO.puts("✅ Session #{session_id} created successfully!")
        IO.puts("   Session data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Session creation failed: #{inspect(reason)}")
    end
  end

  defp test_session_state_persistence do
    IO.puts("\n🔄 Testing session state persistence...")
    
    session_id = "persistent_session_#{System.os_time(:millisecond)}"
    
    # First operation - store some data
    case Snakepit.execute_in_session(session_id, "echo", %{
      operation: "store",
      key: "username", 
      value: "alice"
    }) do
      {:ok, result} ->
        IO.puts("✅ First operation in session: stored username")
        IO.puts("   Data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ First operation failed: #{inspect(reason)}")
    end
    
    # Second operation - should maintain session context
    case Snakepit.execute_in_session(session_id, "echo", %{
      operation: "store",
      key: "email",
      value: "alice@example.com"
    }) do
      {:ok, result} ->
        IO.puts("✅ Second operation in session: stored email")
        IO.puts("   Data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Second operation failed: #{inspect(reason)}")
    end
    
    # Third operation - retrieve stored data
    case Snakepit.execute_in_session(session_id, "echo", %{
      operation: "retrieve",
      key: "username"
    }) do
      {:ok, result} ->
        IO.puts("✅ Third operation: retrieved data from session")
        IO.puts("   Retrieved: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Third operation failed: #{inspect(reason)}")
    end
  end

  defp test_session_data_accumulation do
    IO.puts("\n📊 Testing session data accumulation...")
    
    session_id = "accumulation_session_#{System.os_time(:millisecond)}"
    
    # Accumulate data across multiple operations
    operations = [
      %{action: "add_item", item: "apple", count: 5},
      %{action: "add_item", item: "banana", count: 3}, 
      %{action: "add_item", item: "orange", count: 8},
      %{action: "calculate_total"}
    ]
    
    Enum.each(operations, fn operation ->
      case Snakepit.execute_in_session(session_id, "echo", operation) do
        {:ok, result} ->
          IO.puts("✅ Operation: #{operation[:action]} -> #{inspect(result["echoed"])}")
        {:error, reason} ->
          IO.puts("❌ Operation #{operation[:action]} failed: #{inspect(reason)}")
      end
    end)
    
    # Get final session state
    case Snakepit.execute_in_session(session_id, "echo", %{action: "get_session_summary"}) do
      {:ok, result} ->
        IO.puts("✅ Session summary: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Session summary failed: #{inspect(reason)}")
    end
  end

  defp test_session_cleanup do
    IO.puts("\n🧹 Testing session cleanup...")
    
    session_id = "cleanup_session_#{System.os_time(:millisecond)}"
    
    # Create session with data
    Snakepit.execute_in_session(session_id, "echo", %{
      action: "create_temp_data",
      data: %{temp_files: ["file1.tmp", "file2.tmp"], temp_vars: %{x: 1, y: 2}}
    })
    
    # Cleanup session
    case Snakepit.execute_in_session(session_id, "echo", %{action: "cleanup_session"}) do
      {:ok, result} ->
        IO.puts("✅ Session cleanup completed: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Session cleanup failed: #{inspect(reason)}")
    end
  end

  defp show_pool_stats do
    IO.puts("\n📊 Pool Statistics:")
    
    stats = Snakepit.get_stats()
    
    IO.puts("   Workers: #{stats.workers}")
    IO.puts("   Available: #{stats.available}")
    IO.puts("   Busy: #{stats.busy}")
    IO.puts("   Total Requests: #{stats.requests}")
    IO.puts("   Errors: #{stats.errors}")
    
    if stats.errors > 0 do
      IO.puts("   ⚠️ Some errors occurred during testing")
    else
      IO.puts("   ✅ No errors - all session operations succeeded!")
    end
  end
end

# Run the demo
SnakepitSessionDemo.run(pool_size)

# Clean shutdown
IO.puts("\n🛑 Stopping Snakepit application...")
Application.stop(:snakepit)
IO.puts("✅ Demo script complete!")