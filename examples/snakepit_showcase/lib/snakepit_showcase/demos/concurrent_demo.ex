defmodule SnakepitShowcase.Demos.ConcurrentDemo do
  @moduledoc """
  Demonstrates concurrent processing with robust error handling.
  
  Shows best practices for:
  - Handling task failures gracefully
  - Timeout management
  - Pool saturation recovery
  - Resource cleanup
  """

  def run do
    IO.puts("\n⚡ Concurrent Processing Demo\n")
    
    # Demo 1: Parallel execution with error handling
    demo_parallel_execution()
    
    # Demo 2: Pool saturation and recovery
    demo_pool_saturation()
    
    # Demo 3: Performance with failure tolerance
    demo_resilient_benchmark()
    
    :ok
  end

  defp demo_parallel_execution do
    IO.puts("1️⃣ Parallel Execution with Error Handling")
    
    tasks = ["task_1", "task_2", "task_3", "task_4", "task_fail"]
    
    IO.puts("   Executing #{length(tasks)} tasks (including one that fails)...")
    
    start_time = System.monotonic_time(:millisecond)
    
    results = 
      tasks
      |> Task.async_stream(
        fn task_id ->
          execute_task_safely(task_id)
        end,
        max_concurrency: 4,
        timeout: 5000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:error, :timeout}
        {:exit, reason} -> {:error, {:task_crashed, reason}}
      end)
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    IO.puts("\n   Results:")
    Enum.each(results, fn
      {:ok, task_id, result} ->
        IO.puts("     ✅ #{task_id}: computed #{result["result"]} in #{result["actual_duration_ms"]}ms")
      
      {:error, task_id, reason} ->
        IO.puts("     ❌ #{task_id}: failed with #{inspect(reason)}")
      
      {:error, :timeout} ->
        IO.puts("     ⏱️  Task timed out")
    end)
    
    successful = Enum.count(results, fn
      {:ok, _, _} -> true
      _ -> false
    end)
    
    IO.puts("\n   Summary: #{successful}/#{length(tasks)} tasks completed")
    IO.puts("   Total time: #{elapsed}ms")
  end

  defp execute_task_safely(task_id) do
    session_id = "concurrent_#{task_id}"
    
    # Simulate failure for specific task
    if task_id == "task_fail" do
      case Snakepit.execute_in_session(session_id, "error_demo", %{error_type: "runtime"}) do
        {:ok, result} -> {:ok, task_id, result}
        {:error, reason} -> {:error, task_id, reason}
      end
    else
      case Snakepit.execute_in_session(session_id, "cpu_bound_task", %{
        task_id: task_id,
        duration_ms: 1000
      }) do
        {:ok, result} -> {:ok, task_id, result}
        {:error, reason} -> {:error, task_id, reason}
      end
    end
  end

  defp demo_pool_saturation do
    IO.puts("\n2️⃣ Pool Saturation and Recovery")
    
    # Get pool config
    pool_size = Application.get_env(:snakepit, :pool_config)[:pool_size] || 4
    IO.puts("   Pool size: #{pool_size}")
    
    # Try to execute more tasks than pool size
    task_count = pool_size * 3
    IO.puts("   Submitting #{task_count} tasks (3x pool size)...")
    
    # Submit tasks in batches to avoid overwhelming the system
    batch_size = pool_size
    batches = Enum.chunk_every(1..task_count, batch_size)
    
    results = 
      batches
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {batch, batch_num} ->
        IO.puts("\n   Batch #{batch_num}:")
        process_batch_with_retry(batch)
      end)
    
    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))
    
    IO.puts("\n   Final results:")
    IO.puts("   ✅ Successful: #{successful}")
    IO.puts("   ❌ Failed: #{failed}")
    IO.puts("   📊 Success rate: #{round(successful / task_count * 100)}%")
  end

  defp process_batch_with_retry(batch, retry_count \\ 0, max_retries \\ 2) do
    start_time = System.monotonic_time(:millisecond)
    
    tasks = 
      Enum.map(batch, fn i ->
        Task.async(fn ->
          session_id = "saturation_#{i}"
          
          case Snakepit.execute_in_session(session_id, "sleep_task", %{
            duration_ms: 500,
            task_number: i
          }, timeout: 2000) do
            {:ok, _result} -> 
              {:ok, i}
              
            {:error, :timeout} when retry_count < max_retries ->
              {:retry, i}
              
            {:error, reason} ->
              {:error, i, reason}
          end
        end)
      end)
    
    # Use shorter timeout for individual tasks
    results = Task.await_many(tasks, 3000)
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    # Separate successful, failed, and retry candidates
    {to_retry, final_results} = 
      Enum.split_with(results, fn
        {:retry, _} -> true
        _ -> false
      end)
    
    IO.puts("     Processed #{length(batch)} tasks in #{elapsed}ms")
    
    # Retry failed tasks if needed
    if length(to_retry) > 0 and retry_count < max_retries do
      retry_numbers = Enum.map(to_retry, fn {:retry, i} -> i end)
      IO.puts("     Retrying #{length(retry_numbers)} tasks...")
      retry_results = process_batch_with_retry(retry_numbers, retry_count + 1, max_retries)
      final_results ++ retry_results
    else
      # Convert retries to errors if we've exhausted retries
      converted = Enum.map(to_retry, fn {:retry, i} -> 
        {:error, i, :max_retries_exceeded}
      end)
      final_results ++ converted
    end
  end

  defp demo_resilient_benchmark do
    IO.puts("\n3️⃣ Resilient Performance Benchmark")
    
    iterations = 50
    IO.puts("   Running #{iterations} lightweight tasks with failure injection...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Use Flow for better concurrency control
    results = 
      1..iterations
      |> Task.async_stream(
        fn i ->
          # Inject random failures
          if :rand.uniform(10) == 1 do
            {:error, i, :simulated_failure}
          else
            session_id = "bench_#{i}"
            case Snakepit.execute_in_session(session_id, "lightweight_task", %{
              iteration: i
            }, timeout: 1000) do
              {:ok, result} -> {:ok, i, result["result"]}
              {:error, reason} -> {:error, i, reason}
            end
          end
        end,
        max_concurrency: System.schedulers_online(),
        timeout: 2000
      )
      |> Enum.reduce({0, 0, []}, fn
        {:ok, {:ok, i, result}}, {success, errors, results} ->
          {success + 1, errors, [{i, result} | results]}
          
        {:ok, {:error, _i, _reason}}, {success, errors, results} ->
          {success, errors + 1, results}
          
        {:exit, _}, {success, errors, results} ->
          {success, errors + 1, results}
      end)
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    {successful, failed, _} = results
    
    ops_per_second = successful / (elapsed / 1000)
    
    IO.puts("\n   Benchmark results:")
    IO.puts("   Total time: #{elapsed}ms")
    IO.puts("   Successful: #{successful}")
    IO.puts("   Failed: #{failed}")
    IO.puts("   Success rate: #{round(successful / iterations * 100)}%")
    IO.puts("   Throughput: #{round(ops_per_second)} ops/sec")
    
    if failed > iterations * 0.2 do
      IO.puts("\n   ⚠️  High failure rate detected!")
      IO.puts("   Consider:")
      IO.puts("   - Checking worker health")
      IO.puts("   - Increasing pool size")
      IO.puts("   - Adjusting timeouts")
    end
  end
end