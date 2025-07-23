defmodule SnakepitShowcase.Demos.ExecutionModesDemo do
  @moduledoc """
  Demonstrates when to use different Snakepit execution modes.
  
  This demo helps developers understand:
  - When to use stateless vs session-based execution
  - Performance trade-offs between modes
  - Best practices for each execution pattern
  """
  
  def run do
    IO.puts("\n🎯 Execution Modes Demo\n")
    
    demonstrate_stateless_execution()
    demonstrate_session_execution()
    demonstrate_streaming_execution()
    demonstrate_execution_tradeoffs()
  end
  
  defp demonstrate_stateless_execution do
    IO.puts("1️⃣ Stateless Execution (Snakepit.execute/3)")
    IO.puts("   Use for: Idempotent, stateless operations")
    IO.puts("   Examples: Data transformations, calculations, one-off tasks\n")
    
    # Example: Simple calculation
    case Snakepit.execute("echo", %{
      message: "Stateless operations can run on any available worker"
    }) do
      {:ok, result} ->
        IO.puts("   Result: #{inspect(result["echoed"]["message"])}")
      {:error, reason} ->
        IO.puts("   Error: #{inspect(reason)}")
    end
    
    # Example: Parallel stateless operations
    IO.puts("\n   Running parallel stateless operations...")
    
    tasks = for i <- 1..5 do
      Task.async(fn ->
        case Snakepit.execute("lightweight_task", %{iteration: i}) do
          {:ok, result} -> {:ok, i, result["result"]}
          {:error, reason} -> {:error, i, reason}
        end
      end)
    end
    
    results = Task.await_many(tasks)
    
    IO.puts("   Parallel results:")
    Enum.each(results, fn
      {:ok, i, result} -> IO.puts("     Task #{i}: #{result}")
      {:error, i, reason} -> IO.puts("     Task #{i} failed: #{inspect(reason)}")
    end)
    
    IO.puts("\n   ✅ Benefits:")
    IO.puts("      - Maximum concurrency (any worker can handle)")
    IO.puts("      - Better fault tolerance")
    IO.puts("      - Simpler to reason about")
  end
  
  defp demonstrate_session_execution do
    IO.puts("\n2️⃣ Session-based Execution (Snakepit.execute_in_session/4)")
    IO.puts("   Use for: Stateful workflows, ML pipelines, multi-step processes")
    IO.puts("   Benefits: Worker affinity, state preservation, better performance\n")
    
    session_id = "demo_session_#{System.unique_integer()}"
    
    # Initialize session
    case Snakepit.execute_in_session(session_id, "init_session", %{}) do
      {:ok, init_result} ->
        IO.puts("   Session initialized on worker PID: #{init_result["worker_pid"]}")
        
        # Build up state across multiple calls
        IO.puts("\n   Building up state across calls:")
        
        for i <- 1..3 do
          case Snakepit.execute_in_session(session_id, "increment_counter", %{}) do
            {:ok, result} ->
              IO.puts("     Counter after increment #{i}: #{result["value"]}")
            {:error, reason} ->
              IO.puts("     Error incrementing: #{inspect(reason)}")
          end
        end
        
        # State persists across calls in the same session
        case Snakepit.execute_in_session(session_id, "get_counter", %{}) do
          {:ok, result} ->
            IO.puts("     Final counter value: #{result["value"]}")
          {:error, _} ->
            IO.puts("     Error getting counter")
        end
        
        # Cleanup
        Snakepit.execute_in_session(session_id, "cleanup", %{})
        
      {:error, reason} ->
        IO.puts("   Session initialization failed: #{inspect(reason)}")
    end
    
    IO.puts("\n   ✅ Benefits:")
    IO.puts("      - State preserved between calls")
    IO.puts("      - Worker affinity for cache efficiency")
    IO.puts("      - Can maintain expensive objects (ML models)")
  end
  
  defp demonstrate_streaming_execution do
    IO.puts("\n3️⃣ Streaming Execution (execute_stream/execute_in_session_stream)")
    IO.puts("   Use for: Long operations, progress updates, large datasets")
    IO.puts("   Benefits: Progressive results, memory efficiency, better UX\n")
    
    session_id = "stream_demo_#{System.unique_integer()}"
    
    IO.puts("   Streaming progress updates:")
    
    case Snakepit.execute_in_session_stream(
      session_id,
      "stream_progress", 
      %{steps: 5}
    ) do
      {:ok, stream} ->
        stream
        |> Enum.each(fn chunk ->
          IO.puts("     Step #{chunk["step"]}/#{chunk["total"]}: " <>
                 "#{chunk["progress"]}% - #{chunk["message"]}")
        end)
        
      {:error, reason} ->
        IO.puts("   Streaming failed: #{inspect(reason)}")
    end
    
    IO.puts("\n   ✅ Benefits:")
    IO.puts("      - Progressive feedback for long operations")
    IO.puts("      - Memory efficient for large data")
    IO.puts("      - Can be cancelled mid-stream")
  end
  
  defp demonstrate_execution_tradeoffs do
    IO.puts("\n4️⃣ Execution Mode Trade-offs")
    IO.puts("""
    
    Stateless (execute/3):
    ✅ Maximum concurrency - any worker can handle the request
    ✅ Better fault tolerance - worker crashes don't lose state
    ✅ Simpler to reason about
    ❌ No state preservation between calls
    ❌ Can't build up complex in-memory structures
    
    Session-based (execute_in_session/4):
    ✅ State preservation across calls
    ✅ Worker affinity for better cache usage
    ✅ Can maintain expensive objects (ML models, connections)
    ❌ Limited to one worker per session
    ❌ State lost if worker crashes
    
    Streaming:
    ✅ Progressive results for long operations
    ✅ Memory efficient for large datasets
    ✅ Better user experience with progress updates
    ❌ More complex error handling
    ❌ Can't easily retry failed chunks
    
    Best Practices:
    
    1. Use stateless execution when:
       - Tasks are independent
       - No shared state needed
       - Maximum parallelism desired
       
    2. Use session-based execution when:
       - Building ML pipelines
       - Multi-step workflows
       - Need to preserve expensive computations
       
    3. Use streaming when:
       - Operations take > 1 second
       - Processing large datasets
       - Want to show progress to users
    """)
    
    demonstrate_performance_comparison()
  end
  
  defp demonstrate_performance_comparison do
    IO.puts("\n5️⃣ Performance Comparison")
    
    iterations = 20
    
    # Stateless benchmark
    IO.puts("\n   Stateless execution (#{iterations} tasks):")
    stateless_start = System.monotonic_time(:millisecond)
    
    stateless_tasks = for i <- 1..iterations do
      Task.async(fn ->
        Snakepit.execute("lightweight_task", %{iteration: i})
      end)
    end
    
    Task.await_many(stateless_tasks)
    stateless_time = System.monotonic_time(:millisecond) - stateless_start
    
    # Session-based benchmark
    IO.puts("   Session-based execution (#{iterations} tasks):")
    session_id = "perf_test_#{System.unique_integer()}"
    session_start = System.monotonic_time(:millisecond)
    
    for i <- 1..iterations do
      Snakepit.execute_in_session(session_id, "lightweight_task", %{iteration: i})
    end
    
    session_time = System.monotonic_time(:millisecond) - session_start
    
    IO.puts("\n   Results:")
    IO.puts("   Stateless: #{stateless_time}ms (#{round(iterations / (stateless_time / 1000))} ops/sec)")
    IO.puts("   Session-based: #{session_time}ms (#{round(iterations / (session_time / 1000))} ops/sec)")
    
    if stateless_time < session_time do
      speedup = Float.round(session_time / stateless_time, 2)
      IO.puts("\n   ⚡ Stateless was #{speedup}x faster for independent tasks")
    else
      speedup = Float.round(stateless_time / session_time, 2)
      IO.puts("\n   ⚡ Session-based was #{speedup}x faster (likely due to worker warmup)")
    end
  end
end