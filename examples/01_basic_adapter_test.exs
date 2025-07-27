#!/usr/bin/env elixir

# Load Snakepit as a dependency
Mix.install([{:snakepit, path: ".", override: true}])

# Configure the adapter before starting the application
Application.put_env(:snakepit, :adapter_module, nil)
Application.put_env(:snakepit, :pooling_enabled, false)

# Example 01: Basic Adapter Implementation (Test Version)
# 
# This example demonstrates the simplest possible Snakepit adapter.
# It shows the core contract without any external dependencies.

defmodule BasicAdapter do
  @moduledoc """
  A minimal adapter that processes commands in-memory.
  
  This demonstrates:
  - Required execute/3 callback
  - Basic command handling
  - Error scenarios
  """
  
  @behaviour Snakepit.Adapter
  
  @impl Snakepit.Adapter
  def execute(command, args, _opts) do
    case command do
      "echo" ->
        message = Map.get(args, "message", "Hello, Snakepit!")
        {:ok, message}
        
      "add" ->
        a = Map.get(args, "a", 0)
        b = Map.get(args, "b", 0)
        {:ok, a + b}
        
      "reverse" ->
        text = Map.get(args, "text", "")
        {:ok, String.reverse(text)}
        
      "error" ->
        {:error, "This is an intentional error"}
        
      "slow" ->
        delay = Map.get(args, "delay", 100)
        Process.sleep(delay)
        {:ok, "Completed after #{delay}ms"}
        
      _ ->
        {:error, "Unknown command: #{command}"}
    end
  end
end

# Test the adapter without starting the full application
defmodule BasicAdapterTest do
  def run do
    IO.puts("\n=== Basic Adapter Test ===\n")
    
    # Test 1: Direct adapter execution
    IO.puts("1. Direct adapter calls:")
    
    {:ok, result} = BasicAdapter.execute("echo", %{"message" => "Direct test!"}, [])
    IO.puts("   Echo: #{result}")
    
    {:ok, sum} = BasicAdapter.execute("add", %{"a" => 10, "b" => 20}, [])
    IO.puts("   Add: 10 + 20 = #{sum}")
    
    {:ok, reversed} = BasicAdapter.execute("reverse", %{"text" => "elixir"}, [])
    IO.puts("   Reverse: 'elixir' -> '#{reversed}'")
    
    {:error, error} = BasicAdapter.execute("error", %{}, [])
    IO.puts("   Error: #{error}")
    
    # Test 2: Adapter validation
    IO.puts("\n2. Adapter validation:")
    case Snakepit.Adapter.validate_implementation(BasicAdapter) do
      :ok -> IO.puts("   ✓ BasicAdapter properly implements Snakepit.Adapter")
      {:error, missing} -> IO.puts("   ✗ Missing callbacks: #{inspect(missing)}")
    end
    
    # Test 3: Performance test
    IO.puts("\n3. Performance test (100 operations):")
    start = System.monotonic_time(:millisecond)
    
    for i <- 1..100 do
      BasicAdapter.execute("add", %{"a" => i, "b" => i}, [])
    end
    
    elapsed = System.monotonic_time(:millisecond) - start
    IO.puts("   Completed 100 operations in #{elapsed}ms")
    IO.puts("   Average: #{Float.round(elapsed / 100, 2)}ms per operation")
    
    IO.puts("\n=== Test completed successfully! ===\n")
  end
end

# Run the test
BasicAdapterTest.run()

# Note: To test with the full Snakepit pool, you would need to:
# 1. Configure the adapter: Application.put_env(:snakepit, :adapter_module, BasicAdapter)
# 2. Start the application: Application.ensure_all_started(:snakepit)
# 3. Use Snakepit.execute/3 instead of direct adapter calls