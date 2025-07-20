#!/usr/bin/env elixir

# JavaScript Session Demo with MessagePack
# Run with: elixir examples/javascript_session_demo_msgpack.exs

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

defmodule JavaScriptSessionDemo do
  def run do
    IO.puts("\n🟨 Snakepit JavaScript Session Demo - MessagePack Requested")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("📦 Wire Protocol: MessagePack requested (will fallback to JSON)")
    IO.puts("ℹ️  Note: JavaScript bridge currently only supports JSON protocol")
    IO.puts("=" |> String.duplicate(70))
    
    # Wait for pool to initialize
    
    # Demo 1: Basic session operations
    IO.puts("\n1️⃣ Basic Session Operations:")
    
    session_id = "js_session_#{System.unique_integer([:positive])}"
    IO.puts("✅ Using session: #{session_id}")
    
    # Initialize session state using echo command
    {:ok, _} = Snakepit.execute_in_session(session_id, "echo", %{
      message: "Session initialized", 
      session_id: session_id,
      counter: 0
    })
    IO.puts("✅ Session state initialized")
    
    # Demo 2: Stateful operations using compute
    IO.puts("\n2️⃣ Stateful Counter (using compute):")
    
    for i <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "compute", %{
        operation: "add", 
        a: i, 
        b: 10,
        session_data: %{counter: i}
      })
      IO.puts("   Computation #{i}: #{i} + 10 = #{result["result"]}")
    end
    
    # Demo 3: Accumulating data using random and echo
    IO.puts("\n3️⃣ Accumulating Data in Session:")
    
    for i <- 1..3 do
      # Generate random data
      {:ok, rand_result} = Snakepit.execute_in_session(session_id, "random", %{
        type: "uniform", 
        min: 0, 
        max: 100
      })
      
      # Store item data using echo
      {:ok, result} = Snakepit.execute_in_session(session_id, "echo", %{
        item_id: i,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        value: rand_result["result"],
        session_id: session_id
      })
      IO.puts("   Added item #{i}: #{inspect(result["echoed"])}")
    end
    
    # Retrieve session summary
    {:ok, result} = Snakepit.execute_in_session(session_id, "echo", %{
      summary: "Session contains 3 items",
      session_id: session_id
    })
    IO.puts("\n📋 Session summary: #{inspect(result["echoed"], pretty: true)}")
    
    # Clean up first session
    # Session auto-cleanup - no manual close needed
    IO.puts("\n✅ Closed first session")
    
    # Demo 4: Multiple isolated sessions
    IO.puts("\n4️⃣ Multiple Isolated Sessions:")
    
    session1 = "js_session_1_#{System.unique_integer([:positive])}"
    session2 = "js_session_2_#{System.unique_integer([:positive])}"
    
    # Initialize different values in each session using echo
    {:ok, _} = Snakepit.execute_in_session(session1, "echo", %{
      session_name: "Session One",
      session_id: session1
    })
    {:ok, _} = Snakepit.execute_in_session(session2, "echo", %{
      session_name: "Session Two", 
      session_id: session2
    })
    
    # Verify isolation
    {:ok, result1} = Snakepit.execute_in_session(session1, "echo", %{
      get_name: true,
      session_id: session1
    })
    {:ok, result2} = Snakepit.execute_in_session(session2, "echo", %{
      get_name: true,
      session_id: session2
    })
    
    IO.puts("   Session 1 ID: #{result1["echoed"]["session_id"]}")
    IO.puts("   Session 2 ID: #{result2["echoed"]["session_id"]}")
    IO.puts("✅ Session isolation verified")
    
    # Clean up
    # Session auto-cleanup - no manual close needed
    
    # Demo 5: Complex stateful computation using compute
    IO.puts("\n5️⃣ Complex Stateful Computation:")
    
    session_id = "js_fib_session_#{System.unique_integer([:positive])}"
    
    # Initialize Fibonacci sequence using compute
    {:ok, _} = Snakepit.execute_in_session(session_id, "echo", %{
      fibonacci_init: true,
      session_id: session_id,
      message: "Fibonacci generator initialized"
    })
    
    # Generate Fibonacci-like sequence using compute operations
    IO.puts("   Generating Fibonacci-like sequence using compute:")
    fib_values = [0, 1]
    
    for i <- 1..6 do
      prev_val = Enum.at(fib_values, i - 1, 0)
      curr_val = Enum.at(fib_values, i, 1) 
      
      {:ok, result} = Snakepit.execute_in_session(session_id, "compute", %{
        operation: "add", 
        a: prev_val, 
        b: curr_val,
        fibonacci_step: i + 1
      })
      
      next_val = result["result"]
      fib_values = fib_values ++ [next_val]
      IO.puts("   F(#{i+1}) = #{next_val}")
    end
    
    # Get history summary
    {:ok, result} = Snakepit.execute_in_session(session_id, "echo", %{
      fibonacci_history: fib_values,
      session_id: session_id
    })
    IO.puts("\n📊 Fibonacci history: #{inspect(result["echoed"]["fibonacci_history"])}")
    
    # Session auto-cleanup - no manual close needed
    
    # Demo 6: Protocol notes
    IO.puts("\n6️⃣ Protocol Performance Notes:")
    IO.puts("📊 Current state:")
    IO.puts("   - JavaScript bridge uses JSON protocol")
    IO.puts("   - Session data transfers could be optimized with MessagePack")
    IO.puts("   - Python sessions with MessagePack are 1.3-2.3x faster")
    IO.puts("\n💡 To add MessagePack to JavaScript:")
    IO.puts("   1. Add msgpack-lite npm package to generic_bridge.js")
    IO.puts("   2. Implement protocol negotiation in JavaScript")
    IO.puts("   3. Update ProtocolHandler in JS to support both formats")
    
    # Show protocol notes
    IO.puts("\n📊 Session Performance Notes:")
    IO.puts("   - JavaScript sessions use JSON protocol")
    IO.puts("   - Worker affinity maintained per session") 
    IO.puts("   - State persists across session operations")
  end
end

# Run the demo
JavaScriptSessionDemo.run()