#!/usr/bin/env elixir

# Session-Based Snakepit JavaScript Demo
# Run with: elixir examples/javascript_session_demo.exs [pool_size]
# Example: elixir examples/javascript_session_demo.exs 8

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
    IO.puts("⚠️ Usage: elixir examples/javascript_session_demo.exs [pool_size]")
    IO.puts("⚠️ Using default pool size: 4")
    4
end

# Configure Snakepit for session-based execution with JavaScript
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: pool_size
})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitJavaScriptSessionDemo do
  def run(pool_size) do
    IO.puts("\n🔗 Snakepit JavaScript Session-Based Execution Demo")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("🟨 Pool Size: #{pool_size} JavaScript workers")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Check if pool is running
    pool_pid = Process.whereis(Snakepit.Pool)

    if pool_pid do
      IO.puts("\n✅ Pool started successfully: #{inspect(pool_pid)}")
      
      # Test session-based execution with JavaScript
      test_session_creation()
      test_session_state_persistence()
      test_session_data_accumulation()
      test_session_random_state()
      test_session_cleanup()
      show_pool_stats()
      
      IO.puts("\n🎯 All JavaScript session tests completed!")
    else
      IO.puts("\n❌ Pool not found! Check configuration.")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp test_session_creation do
    IO.puts("\n📝 Testing JavaScript session creation and initialization...")
    
    session_id = "js_session_#{System.os_time(:millisecond)}"
    
    # Initialize session with some state
    case Snakepit.execute_in_session(session_id, "echo", %{
      action: "initialize_session",
      session_data: %{counter: 0, objects: [], operations: []}
    }) do
      {:ok, result} ->
        IO.puts("✅ JavaScript session #{session_id} created successfully!")
        IO.puts("   Session data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Session creation failed: #{inspect(reason)}")
    end
  end

  defp test_session_state_persistence do
    IO.puts("\n🔄 Testing JavaScript session state persistence...")
    
    session_id = "js_persistent_session_#{System.os_time(:millisecond)}"
    
    # First operation - store some JavaScript objects
    case Snakepit.execute_in_session(session_id, "echo", %{
      operation: "store_object",
      object_type: "user", 
      data: %{name: "Alice", age: 30, skills: ["JavaScript", "Node.js"]}
    }) do
      {:ok, result} ->
        IO.puts("✅ First operation in session: stored user object")
        IO.puts("   Data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ First operation failed: #{inspect(reason)}")
    end
    
    # Second operation - store configuration
    case Snakepit.execute_in_session(session_id, "echo", %{
      operation: "store_config",
      config: %{theme: "dark", language: "en", notifications: true}
    }) do
      {:ok, result} ->
        IO.puts("✅ Second operation in session: stored config")
        IO.puts("   Data: #{inspect(result["echoed"])}")
      {:error, reason} ->
        IO.puts("❌ Second operation failed: #{inspect(reason)}")
    end
    
    # Third operation - perform computation with stored data
    case Snakepit.execute_in_session(session_id, "compute", %{
      operation: "power",
      a: 2,
      b: 5
    }) do
      {:ok, result} ->
        IO.puts("✅ Third operation: JavaScript power calculation")
        IO.puts("   2^5 = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Third operation failed: #{inspect(reason)}")
    end
  end

  defp test_session_data_accumulation do
    IO.puts("\n📊 Testing JavaScript session data accumulation...")
    
    session_id = "js_accumulation_session_#{System.os_time(:millisecond)}"
    
    # Accumulate JavaScript-specific data across multiple operations
    operations = [
      %{action: "add_function", name: "factorial", complexity: "O(n)"},
      %{action: "add_function", name: "fibonacci", complexity: "O(2^n)"}, 
      %{action: "add_function", name: "quicksort", complexity: "O(n log n)"},
      %{action: "calculate_total_complexity"}
    ]
    
    Enum.each(operations, fn operation ->
      case Snakepit.execute_in_session(session_id, "echo", operation) do
        {:ok, result} ->
          IO.puts("✅ Operation: #{operation[:action]} -> #{inspect(result["echoed"])}")
        {:error, reason} ->
          IO.puts("❌ Operation #{operation[:action]} failed: #{inspect(reason)}")
      end
    end)
    
    # Get final session state with JavaScript info
    case Snakepit.execute_in_session(session_id, "info", %{}) do
      {:ok, result} ->
        bridge_info = result["bridge_info"]
        system_info = result["system_info"]
        IO.puts("✅ Session summary with Node.js info:")
        IO.puts("   Bridge: #{bridge_info["name"]} v#{bridge_info["version"]}")
        IO.puts("   Node.js: #{system_info["node_version"]}")
        IO.puts("   Platform: #{system_info["platform"]}")
      {:error, reason} ->
        IO.puts("❌ Session summary failed: #{inspect(reason)}")
    end
  end

  defp test_session_random_state do
    IO.puts("\n🎲 Testing JavaScript session with random number state...")
    
    session_id = "js_random_session_#{System.os_time(:millisecond)}"
    
    # Generate multiple random numbers in the same session
    random_operations = [
      %{type: "uniform", min: 0, max: 1},
      %{type: "integer", min: 1, max: 100},
      %{type: "normal", mean: 50, std: 10}
    ]
    
    Enum.with_index(random_operations, 1)
    |> Enum.each(fn {operation, index} ->
      case Snakepit.execute_in_session(session_id, "random", operation) do
        {:ok, result} ->
          value = if operation.type == "integer", do: result["value"], else: Float.round(result["value"], 3)
          IO.puts("✅ Random #{index} (#{operation.type}): #{value}")
        {:error, reason} ->
          IO.puts("❌ Random #{index} failed: #{inspect(reason)}")
      end
    end)
    
    # Test JavaScript math operations in session
    case Snakepit.execute_in_session(session_id, "compute", %{operation: "sqrt", a: 64}) do
      {:ok, result} ->
        IO.puts("✅ JavaScript sqrt(64) = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Square root failed: #{inspect(reason)}")
    end
  end

  defp test_session_cleanup do
    IO.puts("\n🧹 Testing JavaScript session cleanup...")
    
    session_id = "js_cleanup_session_#{System.os_time(:millisecond)}"
    
    # Create session with JavaScript-specific data
    Snakepit.execute_in_session(session_id, "echo", %{
      action: "create_js_resources",
      data: %{
        event_listeners: ["click", "resize", "scroll"],
        timers: [1001, 1002, 1003],
        dom_elements: ["#header", ".sidebar", ".main-content"]
      }
    })
    
    # Cleanup session
    case Snakepit.execute_in_session(session_id, "echo", %{action: "cleanup_js_session"}) do
      {:ok, result} ->
        IO.puts("✅ JavaScript session cleanup completed: #{inspect(result["echoed"])}")
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
      IO.puts("   ✅ No errors - all JavaScript session operations succeeded!")
    end
  end
end

# Run the demo
SnakepitJavaScriptSessionDemo.run(pool_size)

# Clean shutdown
IO.puts("\n🛑 Stopping Snakepit application...")
Application.stop(:snakepit)
IO.puts("✅ Demo script complete!")