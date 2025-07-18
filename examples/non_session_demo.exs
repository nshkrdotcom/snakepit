#!/usr/bin/env elixir

# Non-Session-Based Snakepit Demo
# Run with: elixir examples/non_session_demo.exs

# Configure Snakepit for stateless execution
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: 4
})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericPython)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitStatelessDemo do
  def run do
    IO.puts("\n⚡ Snakepit Non-Session (Stateless) Execution Demo")
    IO.puts("=" |> String.duplicate(60))

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Check if pool is running
    pool_pid = Process.whereis(Snakepit.Pool)

    if pool_pid do
      IO.puts("\n✅ Pool started successfully: #{inspect(pool_pid)}")
      
      # Test stateless execution
      test_independent_operations()
      test_parallel_computations()
      test_data_processing()
      test_validation_operations()
      test_high_throughput()
      show_pool_stats()
      
      IO.puts("\n🎯 All stateless tests completed!")
    else
      IO.puts("\n❌ Pool not found! Check configuration.")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp test_independent_operations do
    IO.puts("\n🔄 Testing independent operations (no state sharing)...")
    
    # Each operation is completely independent
    operations = [
      {"ping", %{test: "connectivity"}},
      {"compute", %{operation: "add", a: 10, b: 20}},
      {"compute", %{operation: "multiply", a: 7, b: 6}},
      {"echo", %{message: "Hello from operation 4"}},
      {"compute", %{operation: "divide", a: 100, b: 5}}
    ]
    
    Enum.with_index(operations, 1)
    |> Enum.each(fn {{command, args}, index} ->
      case Snakepit.execute(command, args) do
        {:ok, result} ->
          IO.puts("✅ Operation #{index} (#{command}): Success")
          case command do
            "compute" -> 
              IO.puts("   #{args.a} #{args.operation} #{args.b} = #{result["result"]}")
            "echo" -> 
              IO.puts("   Echoed: #{inspect(result["echoed"])}")
            "ping" -> 
              IO.puts("   Status: #{result["status"]}")
          end
        {:error, reason} ->
          IO.puts("❌ Operation #{index} failed: #{inspect(reason)}")
      end
    end)
    
    IO.puts("   Notice: Each operation is completely independent!")
  end

  defp test_parallel_computations do
    IO.puts("\n⚡ Testing parallel stateless computations...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Multiple independent compute tasks
    tasks = for _i <- 1..12 do
      Task.async(fn ->
        operation = Enum.random(["add", "multiply", "divide"])
        a = Enum.random(1..50)
        b = Enum.random(1..20)
        
        Snakepit.execute("compute", %{
          operation: operation,
          a: a,
          b: b
        })
      end)
    end
    
    results = Task.await_many(tasks, 10_000)
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("✅ #{success_count}/12 parallel computations completed in #{elapsed}ms")
    
    # Show sample results
    results
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.take(4)
    |> Enum.with_index(1)
    |> Enum.each(fn {{:ok, result}, i} ->
      inputs = result["inputs"]
      IO.puts("   Result #{i}: #{inputs["a"]} #{inputs["operation"]} #{inputs["b"]} = #{result["result"]}")
    end)
  end

  defp test_data_processing do
    IO.puts("\n📊 Testing stateless data processing...")
    
    # Different data sets processed independently
    datasets = [
      %{name: "numbers", data: [1, 2, 3, 4, 5], transform: "square"},
      %{name: "strings", data: ["hello", "world", "test"], transform: "uppercase"},
      %{name: "mixed", data: [1, "two", 3.14, "four"], transform: "stringify"},
      %{name: "empty", data: [], transform: "count"}
    ]
    
    Enum.each(datasets, fn dataset ->
      case Snakepit.execute("echo", %{
        dataset: dataset.name,
        input: dataset.data,
        transform: dataset.transform,
        processed_at: System.os_time(:millisecond)
      }) do
        {:ok, result} ->
          echoed = result["echoed"]
          IO.puts("✅ Dataset '#{dataset.name}': #{length(dataset.data)} items -> #{echoed["transform"]}")
          IO.puts("   Input: #{inspect(dataset.data)}")
          IO.puts("   Processed at: #{echoed["processed_at"]}")
        {:error, reason} ->
          IO.puts("❌ Dataset '#{dataset.name}' failed: #{inspect(reason)}")
      end
    end)
  end

  defp test_validation_operations do
    IO.puts("\n🔍 Testing validation operations (stateless)...")
    
    # Independent validation tasks
    validations = [
      {"valid_compute", %{operation: "add", a: 5, b: 10}},
      {"invalid_operation", %{operation: "invalid", a: 1, b: 2}},
      {"division_by_zero", %{operation: "divide", a: 10, b: 0}},
      {"valid_ping", %{test: true}},
      {"invalid_command", %{should: "fail"}}
    ]
    
    Enum.each(validations, fn {test_name, args} ->
      command = if test_name == "invalid_command", do: "invalid_cmd", else: "compute"
      
      case Snakepit.execute(command, args) do
        {:ok, _result} ->
          if String.contains?(test_name, "valid") do
            IO.puts("✅ #{test_name}: Expected success")
          else
            IO.puts("⚠️ #{test_name}: Expected failure but got success")
          end
        {:error, reason} ->
          if String.contains?(test_name, "invalid") or String.contains?(test_name, "zero") do
            IO.puts("✅ #{test_name}: Expected failure - #{inspect(reason)}")
          else
            IO.puts("❌ #{test_name}: Unexpected failure - #{inspect(reason)}")
          end
      end
    end)
  end

  defp test_high_throughput do
    IO.puts("\n🚀 Testing high-throughput stateless operations...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Burst of simple operations
    tasks = for i <- 1..20 do
      Task.async(fn ->
        Snakepit.execute("ping", %{
          request_id: i,
          timestamp: System.os_time(:millisecond)
        })
      end)
    end
    
    results = Task.await_many(tasks, 15_000)
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    throughput = if elapsed > 0 do
      Float.round(success_count / (elapsed / 1000), 1)
    else
      Float.round(success_count / 0.001, 1)  # Assume 1ms minimum
    end
    
    IO.puts("✅ #{success_count}/20 high-throughput operations completed")
    IO.puts("   Total time: #{elapsed}ms")
    IO.puts("   Throughput: #{throughput} operations/second")
    IO.puts("   Each operation was completely independent!")
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
      IO.puts("   ✅ No errors - all stateless operations succeeded!")
    end
  end
end

# Run the demo
SnakepitStatelessDemo.run()

# Clean shutdown
IO.puts("\n🛑 Stopping Snakepit application...")
Application.stop(:snakepit)
IO.puts("✅ Demo script complete!")