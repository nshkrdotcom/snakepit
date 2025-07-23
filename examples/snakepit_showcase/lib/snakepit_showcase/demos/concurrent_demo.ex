defmodule SnakepitShowcase.Demos.ConcurrentDemo do
  @moduledoc """
  Demonstrates concurrent processing including parallel task execution,
  pool saturation handling, and performance benchmarking.
  """

  def run do
    IO.puts("⚡ Concurrent Processing Demo\n")
    
    # Demo 1: Parallel execution
    demo_parallel_execution()
    
    # Demo 2: Pool saturation
    demo_pool_saturation()
    
    # Demo 3: Performance benchmark
    demo_performance_benchmark()
    
    # Demo 4: Resource management
    demo_resource_management()
    
    :ok
  end

  defp demo_parallel_execution do
    IO.puts("1️⃣ Parallel Execution")
    
    tasks = ["task_1", "task_2", "task_3", "task_4", "task_5"]
    
    IO.puts("   Executing #{length(tasks)} tasks in parallel...")
    
    start_time = System.monotonic_time(:millisecond)
    
    results = 
      tasks
      |> Task.async_stream(fn task_id ->
        session_id = "concurrent_#{task_id}"
        {:ok, result} = Snakepit.execute_in_session(session_id, "cpu_bound_task", %{
          task_id: task_id,
          duration_ms: 1000
        })
        {task_id, result}
      end, max_concurrency: 4, timeout: 5000)
      |> Enum.map(fn {:ok, result} -> result end)
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("   Results:")
    Enum.each(results, fn {task_id, result} ->
      IO.puts("     #{task_id}: computed #{result["result"]} in #{result["actual_duration_ms"]}ms")
    end)
    
    IO.puts("   Total time: #{elapsed}ms (vs ~5000ms sequential)")
  end

  defp demo_pool_saturation do
    IO.puts("\n2️⃣ Pool Saturation Handling")
    
    # Get pool config
    pool_size = Application.get_env(:snakepit, :pool_config)[:pool_size] || 4
    IO.puts("   Pool size: #{pool_size}")
    
    # Try to execute more tasks than pool size
    task_count = pool_size * 2
    IO.puts("   Submitting #{task_count} concurrent tasks...")
    
    start_time = System.monotonic_time(:millisecond)
    
    tasks = 
      Enum.map(1..task_count, fn i ->
        Task.async(fn ->
          try do
            session_id = "saturation_test_#{i}"
            {:ok, _} = Snakepit.execute_in_session(session_id, "sleep_task", %{
              duration_ms: 500,
              task_number: i
            })
            {:ok, i}
          catch
            :exit, _ -> {:timeout, i}
          end
        end)
      end)
    
    results = Task.await_many(tasks, 10_000)
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    successful = Enum.count(results, fn {status, _} -> status == :ok end)
    timeouts = Enum.count(results, fn {status, _} -> status == :timeout end)
    
    IO.puts("   Completed in #{elapsed}ms")
    IO.puts("   Successful: #{successful}")
    IO.puts("   Timeouts: #{timeouts}")
  end

  defp demo_performance_benchmark do
    IO.puts("\n3️⃣ Performance Benchmark")
    
    iterations = 100
    IO.puts("   Running #{iterations} iterations...")
    
    # Sequential benchmark
    seq_start = System.monotonic_time(:millisecond)
    Enum.each(1..iterations, fn i ->
      {:ok, _} = Snakepit.execute("lightweight_task", %{iteration: i})
    end)
    seq_time = System.monotonic_time(:millisecond) - seq_start
    
    # Concurrent benchmark
    conc_start = System.monotonic_time(:millisecond)
    1..iterations
    |> Task.async_stream(fn i ->
      Snakepit.execute("lightweight_task", %{iteration: i})
    end, max_concurrency: 10, timeout: 5000)
    |> Stream.run()
    conc_time = System.monotonic_time(:millisecond) - conc_start
    
    IO.puts("   Sequential: #{seq_time}ms (#{div(seq_time, iterations)}ms per task)")
    IO.puts("   Concurrent: #{conc_time}ms (#{Float.round(conc_time / iterations, 2)}ms per task)")
    IO.puts("   Speedup: #{Float.round(seq_time / conc_time, 2)}x")
  end

  defp demo_resource_management do
    IO.puts("\n4️⃣ Resource Management")
    
    IO.puts("   Testing worker lifecycle...")
    
    # Create multiple sessions
    sessions = Enum.map(1..5, fn i -> "resource_test_#{i}" end)
    
    # Use them
    IO.puts("   Creating 5 sessions...")
    Enum.each(sessions, fn session_id ->
      {:ok, _} = Snakepit.execute_in_session(session_id, "init_session", %{})
    end)
    
    # Check resource usage
    {:ok, stats} = Snakepit.execute("get_pool_stats", %{})
    IO.puts("   Active workers: #{stats["active_workers"]}")
    IO.puts("   Memory usage: #{stats["memory_mb"]}MB")
    
    # Cleanup
    IO.puts("   Cleaning up sessions...")
    Enum.each(sessions, fn session_id ->
      {:ok, _} = Snakepit.execute_in_session(session_id, "cleanup", %{})
    end)
    
    # Check again
    {:ok, stats} = Snakepit.execute("get_pool_stats", %{})
    IO.puts("   Active workers after cleanup: #{stats["active_workers"]}")
    IO.puts("   Memory usage after cleanup: #{stats["memory_mb"]}MB")
  end
end