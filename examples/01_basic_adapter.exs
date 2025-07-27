#!/usr/bin/env elixir

# Example 01: Basic Adapter Implementation
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

# Start the Snakepit application first
Application.ensure_all_started(:snakepit)

# Configure Snakepit to use our basic adapter
Application.put_env(:snakepit, :adapter_module, BasicAdapter)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Use run_as_script for proper cleanup
Snakepit.run_as_script(fn ->
  IO.puts("\n=== Basic Adapter Example ===\n")
  
  # Example 1: Simple echo
  IO.puts("1. Echo command:")
  {:ok, result} = Snakepit.execute("echo", %{"message" => "Hello from Elixir!"})
  IO.puts("   Result: #{result}")
  
  # Example 2: Math operation
  IO.puts("\n2. Add command:")
  {:ok, sum} = Snakepit.execute("add", %{"a" => 15, "b" => 27})
  IO.puts("   15 + 27 = #{sum}")
  
  # Example 3: String manipulation
  IO.puts("\n3. Reverse command:")
  {:ok, reversed} = Snakepit.execute("reverse", %{"text" => "Snakepit"})
  IO.puts("   'Snakepit' reversed is '#{reversed}'")
  
  # Example 4: Error handling
  IO.puts("\n4. Error handling:")
  case Snakepit.execute("error", %{}) do
    {:error, reason} -> IO.puts("   Got expected error: #{reason}")
    _ -> IO.puts("   Unexpected success!")
  end
  
  # Example 5: Unknown command
  IO.puts("\n5. Unknown command:")
  case Snakepit.execute("unknown", %{}) do
    {:error, reason} -> IO.puts("   Got expected error: #{reason}")
    _ -> IO.puts("   Unexpected success!")
  end
  
  # Example 6: Concurrent execution
  IO.puts("\n6. Concurrent execution (2 workers):")
  
  tasks = for i <- 1..4 do
    Task.async(fn ->
      start = System.monotonic_time(:millisecond)
      {:ok, result} = Snakepit.execute("slow", %{"delay" => 50})
      elapsed = System.monotonic_time(:millisecond) - start
      {i, result, elapsed}
    end)
  end
  
  results = Task.await_many(tasks)
  for {i, result, elapsed} <- results do
    IO.puts("   Task #{i}: #{result} (took #{elapsed}ms)")
  end
  
  # Example 7: Pool statistics
  IO.puts("\n7. Pool statistics:")
  stats = Snakepit.get_stats()
  IO.inspect(stats, label: "   Pool stats")
  
  IO.puts("\n=== Example completed successfully! ===\n")
end)

# Key Concepts Demonstrated:
#
# 1. MINIMAL CONTRACT: Only execute/3 is required
# 2. NO EXTERNAL DEPS: This adapter needs no Python, gRPC, or other processes
# 3. POOLING WORKS: Even this simple adapter benefits from worker pooling
# 4. ERROR HANDLING: Adapters return {:ok, result} or {:error, reason}
# 5. CONCURRENT SAFETY: Multiple workers can execute simultaneously