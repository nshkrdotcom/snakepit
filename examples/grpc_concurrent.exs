#!/usr/bin/env elixir

# Concurrent Operations with gRPC Example
# Demonstrates parallel task execution and pool utilization
#
# Usage: elixir examples/grpc_concurrent.exs [pool_size]
# Default pool_size: 4
# Example: elixir examples/grpc_concurrent.exs 100

pool_size = case System.argv() do
  [size_str] ->
    case Integer.parse(size_str) do
      {size, ""} when size > 0 -> size
      _ ->
        IO.puts("⚠️ Invalid pool size '#{size_str}', using default: 4")
        4
    end
  [] -> 4
  _ ->
    IO.puts("⚠️ Usage: elixir examples/grpc_concurrent.exs [pool_size]")
    IO.puts("Using default: 4")
    4
end

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: pool_size})
Application.put_env(:snakepit, :grpc_port, 50051)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

defmodule ConcurrentExample do
  def run(pool_size) do
    IO.puts("\n=== Concurrent Operations Example ===")
    IO.puts("Pool Size: #{pool_size} workers\n")

    # 1. Simple parallel execution
    IO.puts("1. Parallel task execution:")
    
    tasks = for i <- 1..10 do
      Task.async(fn ->
        start = System.monotonic_time(:millisecond)
        case Snakepit.execute("add", %{a: i, b: i}) do
          {:ok, result} ->
            duration = System.monotonic_time(:millisecond) - start
            {i, result, duration}
          {:error, reason} ->
            {i, {:error, reason}, 0}
        end
      end)
    end

    results = Task.await_many(tasks, 10_000)
    Enum.each(results, fn {id, result, duration} ->
      IO.puts("  Task #{id}: result=#{inspect(result)}, duration=#{duration}ms")
    end)
    
    # 2. Pool saturation test
    IO.puts("\n2. Pool saturation test (4 workers, 20 tasks):")
    
    start_time = System.monotonic_time(:millisecond)
    
    tasks = for i <- 1..20 do
      Task.async(fn ->
        task_start = System.monotonic_time(:millisecond)
        wait_time = task_start - start_time
        
        {:ok, result} = Snakepit.execute("echo", %{
          task_id: i,
          message: "Task #{i}"
        })
        
        task_end = System.monotonic_time(:millisecond)
        {i, wait_time, task_end - task_start, result["worker_id"]}
      end)
    end
    
    results = Task.await_many(tasks, 30_000)
    
    # Analyze worker distribution
    worker_counts = Enum.reduce(results, %{}, fn {_id, _wait, _duration, worker_id}, acc ->
      Map.update(acc, worker_id || "unknown", 1, &(&1 + 1))
    end)
    
    IO.puts("  Worker distribution:")
    Enum.each(worker_counts, fn {worker_id, count} ->
      IO.puts("    Worker #{worker_id}: #{count} tasks")
    end)
    
    total_time = System.monotonic_time(:millisecond) - start_time
    IO.puts("  Total execution time: #{total_time}ms")
    IO.puts("  Theoretical minimum (20 tasks / 4 workers * 500ms): #{20 / 4 * 500}ms")
    
    # 3. Mixed operation types
    IO.puts("\n3. Mixed concurrent operations:")
    
    mixed_tasks = [
      # Fast operations
      for i <- 1..5 do
        Task.async(fn ->
          {:ok, result} = Snakepit.execute("ping", %{id: "fast_#{i}"})
          {:fast, i, result}
        end)
      end,
      
      # Medium operations
      for i <- 1..3 do
        Task.async(fn ->
          {:ok, result} = Snakepit.execute("echo", %{
            id: "medium_#{i}",
            message: "Medium task #{i}"
          })
          {:medium, i, result}
        end)
      end,
      
      # Slow operations
      for i <- 1..2 do
        Task.async(fn ->
          {:ok, result} = Snakepit.execute("echo", %{
            id: "slow_#{i}",
            message: "Slow task #{i}"
          })
          {:slow, i, result}
        end)
      end
    ] |> List.flatten()
    
    mixed_results = Task.await_many(mixed_tasks, 15_000)
    
    IO.puts("  Completed #{length(mixed_results)} mixed operations")
    
    # 4. Session-based concurrent operations
    IO.puts("\n4. Concurrent session operations:")
    
    # Create multiple sessions
    sessions = for i <- 1..3 do
      "concurrent_session_#{i}"
    end
    
    # Initialize sessions concurrently
    init_tasks = for session <- sessions do
      Task.async(fn ->
        {:ok, _} = Snakepit.execute_in_session(session, "ping", %{})
        {:ok, _} = Snakepit.execute_in_session(session, "register_variable", %{
          name: "counter",
          type: "integer",
          initial_value: 0
        })
        session
      end)
    end
    
    Task.await_many(init_tasks)
    
    # Concurrent updates to different sessions
    update_tasks = for _ <- 1..5 do
      for session <- sessions do
        Task.async(fn ->
          {:ok, result} = Snakepit.execute_in_session(session, "set_variable", %{
            name: "counter",
            value: :rand.uniform(100)
          })
          {session, result["value"]}
        end)
      end
    end |> List.flatten()
    
    update_results = Task.await_many(update_tasks, 10_000)
    
    # Get final values
    final_tasks = for session <- sessions do
      Task.async(fn ->
        {:ok, result} = Snakepit.execute_in_session(session, "get_variable", %{
          name: "counter"
        })
        {session, result["value"]}
      end)
    end
    
    final_values = Task.await_many(final_tasks)
    IO.puts("  Final session values:")
    Enum.each(final_values, fn {session, value} ->
      IO.puts("    #{session}: #{value}")
    end)
    
    # Cleanup sessions
    cleanup_tasks = for session <- sessions do
      Task.async(fn ->
        Snakepit.execute_in_session(session, "cleanup_session", %{delete_all: true})
      end)
    end
    Task.await_many(cleanup_tasks)
    
    # 5. Performance benchmark
    IO.puts("\n5. Performance benchmark:")
    
    operation_counts = [10, 50, 100, 200]
    
    for count <- operation_counts do
      start = System.monotonic_time(:millisecond)
      
      tasks = for i <- 1..count do
        Task.async(fn ->
          Snakepit.execute("echo", %{message: "test_#{i}"})
        end)
      end
      
      Task.await_many(tasks, 30_000)
      
      duration = System.monotonic_time(:millisecond) - start
      rate = Float.round(count * 1000 / duration, 1)
      
      IO.puts("  #{count} operations: #{duration}ms (#{rate} ops/sec)")
    end
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  ConcurrentExample.run(pool_size)
end)
