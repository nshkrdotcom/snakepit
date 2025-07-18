#!/usr/bin/env elixir

# Non-Session-Based Snakepit JavaScript Demo
# Run with: elixir examples/javascript_stateless_demo.exs

# Configure Snakepit for stateless execution with JavaScript
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: 4
})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitJavaScriptStatelessDemo do
  def run do
    IO.puts("\n⚡ Snakepit JavaScript Non-Session (Stateless) Execution Demo")
    IO.puts("=" |> String.duplicate(60))

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Check if pool is running
    pool_pid = Process.whereis(Snakepit.Pool)

    if pool_pid do
      IO.puts("\n✅ Pool started successfully: #{inspect(pool_pid)}")
      
      # Test stateless execution with JavaScript
      test_independent_operations()
      test_parallel_computations()
      test_javascript_specific_operations()
      test_random_operations()
      test_validation_operations()
      test_high_throughput()
      show_pool_stats()
      
      IO.puts("\n🎯 All JavaScript stateless tests completed!")
    else
      IO.puts("\n❌ Pool not found! Check configuration.")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp test_independent_operations do
    IO.puts("\n🔄 Testing independent JavaScript operations (no state sharing)...")
    
    # Each operation is completely independent
    operations = [
      {"ping", %{test: "javascript_connectivity"}},
      {"compute", %{operation: "add", a: 15, b: 25}},
      {"compute", %{operation: "power", a: 3, b: 4}},
      {"compute", %{operation: "sqrt", a: 144}},
      {"echo", %{message: "Hello from Node.js"}},
      {"random", %{type: "integer", min: 1, max: 6}}
    ]
    
    Enum.with_index(operations, 1)
    |> Enum.each(fn {{command, args}, index} ->
      case Snakepit.execute(command, args) do
        {:ok, result} ->
          IO.puts("✅ Operation #{index} (#{command}): Success")
          case command do
            "compute" -> 
              case args do
                %{operation: "power"} -> 
                  IO.puts("   #{args.a}^#{args.b} = #{result["result"]}")
                %{operation: "sqrt"} -> 
                  IO.puts("   √#{args.a} = #{result["result"]}")
                _ -> 
                  IO.puts("   #{args.a} #{args.operation} #{args.b} = #{result["result"]}")
              end
            "echo" -> 
              IO.puts("   Echoed: #{inspect(result["echoed"])}")
            "ping" -> 
              IO.puts("   Status: #{result["status"]}, Node: #{result["node_version"]}")
            "random" ->
              IO.puts("   Random #{args.type}: #{result["value"]}")
          end
        {:error, reason} ->
          IO.puts("❌ Operation #{index} failed: #{inspect(reason)}")
      end
    end)
    
    IO.puts("   Notice: Each JavaScript operation is completely independent!")
  end

  defp test_parallel_computations do
    IO.puts("\n⚡ Testing parallel JavaScript computations...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Multiple independent JavaScript compute tasks
    tasks = for _i <- 1..12 do
      Task.async(fn ->
        operation = Enum.random(["add", "multiply", "power", "sqrt"])
        a = Enum.random(1..50)
        b = if operation == "sqrt", do: nil, else: Enum.random(1..20)
        
        args = if operation == "sqrt" do
          %{operation: operation, a: a * a}  # Ensure positive for sqrt
        else
          %{operation: operation, a: a, b: b}
        end
        
        Snakepit.execute("compute", args)
      end)
    end
    
    results = Task.await_many(tasks, 10_000)
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("✅ #{success_count}/12 parallel JavaScript computations completed in #{elapsed}ms")
    
    # Show sample results
    results
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.take(4)
    |> Enum.with_index(1)
    |> Enum.each(fn {{:ok, result}, i} ->
      inputs = result["inputs"]
      case inputs["operation"] do
        "sqrt" ->
          IO.puts("   Result #{i}: √#{inputs["a"]} = #{Float.round(result["result"], 2)}")
        "power" ->
          IO.puts("   Result #{i}: #{inputs["a"]}^#{inputs["b"]} = #{result["result"]}")
        _ ->
          IO.puts("   Result #{i}: #{inputs["a"]} #{inputs["operation"]} #{inputs["b"]} = #{result["result"]}")
      end
    end)
  end

  defp test_javascript_specific_operations do
    IO.puts("\n🔧 Testing JavaScript-specific operations...")
    
    # Test JavaScript's built-in Math functions
    js_operations = [
      %{operation: "power", a: 2, b: 10, expected: "2^10"},
      %{operation: "sqrt", a: 225, expected: "√225"},
      %{operation: "power", a: 5, b: 3, expected: "5^3"}
    ]
    
    Enum.each(js_operations, fn op ->
      case Snakepit.execute("compute", op) do
        {:ok, result} ->
          IO.puts("✅ JavaScript #{op.expected} = #{result["result"]}")
        {:error, reason} ->
          IO.puts("❌ JavaScript #{op.expected} failed: #{inspect(reason)}")
      end
    end)
    
    # Test JavaScript info
    case Snakepit.execute("info", %{}) do
      {:ok, result} ->
        system_info = result["system_info"]
        IO.puts("✅ Node.js runtime info:")
        IO.puts("   Version: #{system_info["node_version"]}")
        IO.puts("   Platform: #{system_info["platform"]}")
        IO.puts("   Architecture: #{system_info["arch"]}")
        IO.puts("   Memory: #{Float.round(system_info["memory_usage"]["rss"] / 1024 / 1024, 1)} MB")
      {:error, reason} ->
        IO.puts("❌ Info failed: #{inspect(reason)}")
    end
  end

  defp test_random_operations do
    IO.puts("\n🎲 Testing JavaScript random number generation...")
    
    # Test different random distributions
    random_tests = [
      %{type: "uniform", min: 0, max: 1, description: "Uniform (0-1)"},
      %{type: "integer", min: 1, max: 100, description: "Integer (1-100)"},
      %{type: "normal", mean: 0, std: 1, description: "Normal (μ=0, σ=1)"},
      %{type: "integer", min: 1, max: 6, description: "Dice roll (1-6)"}
    ]
    
    Enum.each(random_tests, fn test ->
      case Snakepit.execute("random", Map.drop(test, [:description])) do
        {:ok, result} ->
          value = if test.type == "integer", do: result["value"], else: Float.round(result["value"], 3)
          IO.puts("✅ #{test.description}: #{value}")
        {:error, reason} ->
          IO.puts("❌ #{test.description} failed: #{inspect(reason)}")
      end
    end)
  end

  defp test_validation_operations do
    IO.puts("\n🔍 Testing JavaScript validation operations (stateless)...")
    
    # Independent validation tasks
    validations = [
      {"valid_compute", %{operation: "add", a: 10, b: 20}},
      {"valid_power", %{operation: "power", a: 2, b: 8}},
      {"valid_sqrt", %{operation: "sqrt", a: 64}},
      {"invalid_operation", %{operation: "invalid", a: 1, b: 2}},
      {"negative_sqrt", %{operation: "sqrt", a: -4}},
      {"invalid_random", %{type: "invalid", min: 1, max: 10}},
      {"invalid_command", %{should: "fail"}}
    ]
    
    Enum.each(validations, fn {test_name, args} ->
      command = cond do
        test_name == "invalid_command" -> "invalid_cmd"
        String.contains?(test_name, "random") -> "random"
        true -> "compute"
      end
      
      case Snakepit.execute(command, args) do
        {:ok, result} ->
          if String.contains?(test_name, "valid") do
            case args do
              %{operation: "power"} -> 
                IO.puts("✅ #{test_name}: #{args.a}^#{args.b} = #{result["result"]}")
              %{operation: "sqrt"} -> 
                IO.puts("✅ #{test_name}: √#{args.a} = #{result["result"]}")
              %{type: type} ->
                IO.puts("✅ #{test_name}: #{type} random = #{result["value"]}")
              _ -> 
                IO.puts("✅ #{test_name}: Expected success")
            end
          else
            IO.puts("⚠️ #{test_name}: Expected failure but got success")
          end
        {:error, reason} ->
          if String.contains?(test_name, "invalid") or String.contains?(test_name, "negative") do
            IO.puts("✅ #{test_name}: Expected failure - #{inspect(reason)}")
          else
            IO.puts("❌ #{test_name}: Unexpected failure - #{inspect(reason)}")
          end
      end
    end)
  end

  defp test_high_throughput do
    IO.puts("\n🚀 Testing high-throughput JavaScript operations...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Burst of JavaScript ping operations
    tasks = for i <- 1..20 do
      Task.async(fn ->
        Snakepit.execute("ping", %{
          request_id: i,
          timestamp: System.os_time(:millisecond),
          from: "javascript_test"
        })
      end)
    end
    
    results = Task.await_many(tasks, 15_000)
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    throughput = Float.round(success_count / (elapsed / 1000), 1)
    
    IO.puts("✅ #{success_count}/20 high-throughput JavaScript operations completed")
    IO.puts("   Total time: #{elapsed}ms")
    IO.puts("   Throughput: #{throughput} operations/second")
    IO.puts("   Each JavaScript operation was completely independent!")
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
      IO.puts("   ✅ No errors - all JavaScript stateless operations succeeded!")
    end
  end
end

# Run the demo
SnakepitJavaScriptStatelessDemo.run()

# Clean shutdown
IO.puts("\n🛑 Stopping Snakepit application...")
Application.stop(:snakepit)
IO.puts("✅ Demo script complete!")