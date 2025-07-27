#!/usr/bin/env elixir

# Example 01: Basic Adapter Implementation (Simple Version)
# 
# This example demonstrates the simplest possible Snakepit adapter
# without starting the full application.

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

# Test the adapter directly
defmodule BasicAdapterDemo do
  def run do
    IO.puts("\n=== Basic Adapter Demo ===\n")
    
    # Test 1: Direct adapter execution
    IO.puts("1. Testing adapter commands:")
    
    {:ok, result} = BasicAdapter.execute("echo", %{"message" => "Hello World!"}, [])
    IO.puts("   Echo: #{result}")
    
    {:ok, sum} = BasicAdapter.execute("add", %{"a" => 10, "b" => 20}, [])
    IO.puts("   Add: 10 + 20 = #{sum}")
    
    {:ok, reversed} = BasicAdapter.execute("reverse", %{"text" => "elixir"}, [])
    IO.puts("   Reverse: 'elixir' -> '#{reversed}'")
    
    {:error, error} = BasicAdapter.execute("error", %{}, [])
    IO.puts("   Error: #{error}")
    
    {:error, unknown} = BasicAdapter.execute("unknown_cmd", %{}, [])
    IO.puts("   Unknown: #{unknown}")
    
    # Test 2: Performance test
    IO.puts("\n2. Performance test (100 operations):")
    start = System.monotonic_time(:millisecond)
    
    for i <- 1..100 do
      BasicAdapter.execute("add", %{"a" => i, "b" => i}, [])
    end
    
    elapsed = System.monotonic_time(:millisecond) - start
    IO.puts("   Completed 100 operations in #{elapsed}ms")
    IO.puts("   Average: #{Float.round(elapsed / 100, 2)}ms per operation")
    
    IO.puts("\n=== Demo completed successfully! ===\n")
  end
end

# Run the demo
BasicAdapterDemo.run()

# Key Concepts Demonstrated:
#
# 1. MINIMAL CONTRACT: Only execute/3 is required
# 2. NO EXTERNAL DEPS: This adapter needs no Python, gRPC, or other processes  
# 3. SIMPLE INTERFACE: Commands are strings, args are maps, results are {:ok, _} or {:error, _}
# 4. STATELESS: Each execute call is independent
#
# In a real deployment:
# - Configure this adapter: Application.put_env(:snakepit, :adapter_module, BasicAdapter)
# - Start Snakepit: Application.ensure_all_started(:snakepit)
# - Use pooled execution: Snakepit.execute("echo", %{"message" => "Hello"})