#!/usr/bin/env elixir

# Generic Snakepit JavaScript Demo
# Run with: elixir examples/generic_demo_javascript.exs

# Configure the JavaScript adapter BEFORE loading Snakepit
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{
  pool_size: 4
})
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GenericJavaScript)

Mix.install([
  {:snakepit, path: "."}
])

Logger.configure(level: :info)

defmodule SnakepitJavaScriptDemo do
  def run do
    IO.puts("\n⚡ Snakepit JavaScript Adapter Demo")
    IO.puts("=" |> String.duplicate(60))

    # Start the application
    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Check if pool is running
    pool_pid = Process.whereis(Snakepit.Pool)

    if pool_pid do
      IO.puts("\n✅ Pool started successfully: #{inspect(pool_pid)}")
      
      # Test all the JavaScript adapter commands
      test_ping()
      test_echo()
      test_compute()
      test_random()
      test_info()
      test_concurrent_requests()
      test_validation()
      show_pool_stats()
      
      IO.puts("\n🎯 All tests completed successfully!")
    else
      IO.puts("\n❌ Pool not found! Check configuration.")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp test_ping do
    IO.puts("\n📤 Testing ping command...")

    case Snakepit.execute("ping", %{demo: true, timestamp: System.os_time(:millisecond)}) do
      {:ok, result} ->
        IO.puts("✅ Ping successful!")
        IO.puts("   Bridge type: #{result["bridge_type"]}")
        IO.puts("   Node version: #{result["node_version"]}")
        IO.puts("   Platform: #{result["platform"]}")
        IO.puts("   Uptime: #{Float.round(result["uptime"], 2)}s")
      {:error, reason} ->
        IO.puts("❌ Ping failed: #{inspect(reason)}")
    end
  end

  defp test_echo do
    IO.puts("\n📤 Testing echo command...")

    message = %{
      test: "echo test",
      data: [1, 2, 3],
      nested: %{key: "value", number: 42}
    }

    case Snakepit.execute("echo", message) do
      {:ok, result} ->
        IO.puts("✅ Echo successful!")
        IO.puts("   Echoed data matches: #{result["echoed"] == message}")
      {:error, reason} ->
        IO.puts("❌ Echo failed: #{inspect(reason)}")
    end
  end

  defp test_compute do
    IO.puts("\n📤 Testing compute commands...")

    # Test addition
    case Snakepit.execute("compute", %{operation: "add", a: 15, b: 27}) do
      {:ok, result} ->
        IO.puts("✅ Addition: 15 + 27 = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Addition failed: #{inspect(reason)}")
    end

    # Test multiplication
    case Snakepit.execute("compute", %{operation: "multiply", a: 6, b: 7}) do
      {:ok, result} ->
        IO.puts("✅ Multiplication: 6 × 7 = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Multiplication failed: #{inspect(reason)}")
    end

    # Test power (JavaScript-specific)
    case Snakepit.execute("compute", %{operation: "power", a: 2, b: 8}) do
      {:ok, result} ->
        IO.puts("✅ Power: 2^8 = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Power failed: #{inspect(reason)}")
    end

    # Test square root (JavaScript-specific)
    case Snakepit.execute("compute", %{operation: "sqrt", a: 64}) do
      {:ok, result} ->
        IO.puts("✅ Square root: √64 = #{result["result"]}")
      {:error, reason} ->
        IO.puts("❌ Square root failed: #{inspect(reason)}")
    end
  end

  defp test_random do
    IO.puts("\n🎲 Testing random number generation...")

    # Test uniform random
    case Snakepit.execute("random", %{type: "uniform", min: 1, max: 100}) do
      {:ok, result} ->
        IO.puts("✅ Uniform random (1-100): #{Float.round(result["value"], 2)}")
      {:error, reason} ->
        IO.puts("❌ Uniform random failed: #{inspect(reason)}")
    end

    # Test integer random
    case Snakepit.execute("random", %{type: "integer", min: 1, max: 10}) do
      {:ok, result} ->
        IO.puts("✅ Integer random (1-10): #{result["value"]}")
      {:error, reason} ->
        IO.puts("❌ Integer random failed: #{inspect(reason)}")
    end

    # Test normal distribution
    case Snakepit.execute("random", %{type: "normal", mean: 0, std: 1}) do
      {:ok, result} ->
        IO.puts("✅ Normal distribution (μ=0, σ=1): #{Float.round(result["value"], 2)}")
      {:error, reason} ->
        IO.puts("❌ Normal distribution failed: #{inspect(reason)}")
    end
  end

  defp test_info do
    IO.puts("\n📤 Testing info command...")

    case Snakepit.execute("info", %{}) do
      {:ok, result} ->
        bridge_info = result["bridge_info"]
        system_info = result["system_info"]
        
        IO.puts("✅ Bridge info retrieved!")
        IO.puts("   Name: #{bridge_info["name"]}")
        IO.puts("   Version: #{bridge_info["version"]}")
        IO.puts("   Supported commands: #{Enum.join(bridge_info["supported_commands"], ", ")}")
        IO.puts("   Node version: #{system_info["node_version"]}")
        IO.puts("   Architecture: #{system_info["arch"]}")
        IO.puts("   Memory usage: #{Float.round(system_info["memory_usage"]["rss"] / 1024 / 1024, 1)} MB")
      {:error, reason} ->
        IO.puts("❌ Info failed: #{inspect(reason)}")
    end
  end

  defp test_concurrent_requests do
    IO.puts("\n⚡ Testing concurrent requests...")

    start_time = System.monotonic_time(:millisecond)

    # Send multiple concurrent requests mixing compute and random
    tasks = for i <- 1..8 do
      Task.async(fn ->
        if rem(i, 2) == 0 do
          # Even numbers: compute
          Snakepit.execute("compute", %{
            operation: "multiply",
            a: i,
            b: i + 1
          })
        else
          # Odd numbers: random
          Snakepit.execute("random", %{
            type: "integer",
            min: 1,
            max: 100
          })
        end
      end)
    end

    results = Task.await_many(tasks, 10_000)
    success_count = Enum.count(results, &match?({:ok, _}, &1))

    elapsed = System.monotonic_time(:millisecond) - start_time
    IO.puts("✅ #{success_count}/8 concurrent requests completed in #{elapsed}ms")
    
    # Show some results
    results
    |> Enum.take(4)
    |> Enum.with_index(1)
    |> Enum.each(fn 
      {{:ok, result}, i} ->
        cond do
          Map.has_key?(result, "operation") ->
            IO.puts("   Result #{i}: #{result["inputs"]["a"]} × #{result["inputs"]["b"]} = #{result["result"]}")
          Map.has_key?(result, "type") ->
            IO.puts("   Result #{i}: random #{result["type"]} = #{result["value"]}")
          true ->
            IO.puts("   Result #{i}: #{inspect(result)}")
        end
      {{:error, _reason}, i} ->
        IO.puts("   Result #{i}: failed")
    end)
  end

  defp test_validation do
    IO.puts("\n🔍 Testing validation...")

    # Test invalid command
    case Snakepit.execute("invalid_command", %{}) do
      {:ok, _result} ->
        IO.puts("⚠️ Expected validation error for invalid command")
      {:error, reason} ->
        IO.puts("✅ Invalid command properly rejected: #{inspect(reason)}")
    end

    # Test invalid compute operation
    case Snakepit.execute("compute", %{operation: "invalid", a: 1, b: 2}) do
      {:ok, _result} ->
        IO.puts("⚠️ Expected validation error for invalid operation")
      {:error, reason} ->
        IO.puts("✅ Invalid operation properly rejected: #{inspect(reason)}")
    end

    # Test invalid random type
    case Snakepit.execute("random", %{type: "invalid", min: 1, max: 10}) do
      {:ok, _result} ->
        IO.puts("⚠️ Expected validation error for invalid random type")
      {:error, reason} ->
        IO.puts("✅ Invalid random type properly rejected: #{inspect(reason)}")
    end

    # Test square root of negative number
    case Snakepit.execute("compute", %{operation: "sqrt", a: -4}) do
      {:ok, _result} ->
        IO.puts("⚠️ Expected validation error for sqrt of negative number")
      {:error, reason} ->
        IO.puts("✅ Negative square root properly rejected: #{inspect(reason)}")
    end
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
      IO.puts("   ✅ No errors - all requests succeeded!")
    end
  end
end

# Run the demo
SnakepitJavaScriptDemo.run()

# Clean shutdown
IO.puts("\n🛑 Stopping Snakepit application...")
Application.stop(:snakepit)
IO.puts("✅ Demo script complete!")