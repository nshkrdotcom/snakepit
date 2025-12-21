#!/usr/bin/env elixir

# Advanced gRPC Features Example
# Demonstrates error handling, retries, and real-world patterns

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_size, 4)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 4,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 4})
Application.put_env(:snakepit, :grpc_port, 50051)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

defmodule AdvancedExample do
  def run do
    IO.puts("\n=== Advanced gRPC Features Example ===\n")

    # 1. Pipeline with available tools
    IO.puts("1. Multi-stage pipeline execution:")
    pipeline_example()

    Process.sleep(300)

    # 2. Error handling and graceful degradation
    IO.puts("\n2. Error handling:")
    error_handling_example()

    Process.sleep(300)

    # 3. Concurrent task coordination
    IO.puts("\n3. Concurrent task coordination:")
    concurrent_coordination_example()

    Process.sleep(300)

    # 4. Session-based workflow
    IO.puts("\n4. Session-based workflow:")
    session_workflow_example()

    IO.puts("\n✅ Advanced features demonstration complete")
  end

  defp pipeline_example do
    session_id = "pipeline_#{System.unique_integer([:positive])}"

    # Multi-stage data processing pipeline using available tools
    stages = [
      {"Stage 1: Health Check", "ping", %{}},
      {"Stage 2: Echo Input", "echo",
       %{data: "user_input", timestamp: System.system_time(:second)}},
      {"Stage 3: Computation", "add", %{a: 100, b: 50}},
      {"Stage 4: Final Echo", "echo", %{result: "completed", stage: 4}}
    ]

    results =
      Enum.map(stages, fn {name, tool, params} ->
        case Snakepit.execute_in_session(session_id, tool, params) do
          {:ok, result} ->
            IO.puts("  ✓ #{name}: #{inspect(result)}")
            {:ok, result}

          {:error, reason} ->
            IO.puts("  ✗ #{name}: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)
    IO.puts("\n  Pipeline: #{success_count}/#{length(stages)} stages successful")
  end

  defp error_handling_example do
    # Test graceful error handling
    IO.puts("  Testing non-existent tool (expect graceful error):")

    case Snakepit.execute("nonexistent_tool", %{}) do
      {:ok, unexpected} ->
        IO.puts("    Unexpected success: #{inspect(unexpected)}")

      {:error, reason} ->
        IO.puts("    ✅ Gracefully handled error: #{inspect(reason)}")
    end

    IO.puts("\n  Testing successful operation after error:")

    case Snakepit.execute("ping", %{}) do
      {:ok, _result} ->
        IO.puts("    ✅ System recovered, ping successful")

      {:error, reason} ->
        IO.puts("    ✗ Failed: #{inspect(reason)}")
    end
  end

  defp concurrent_coordination_example do
    # Demonstrate coordinated concurrent operations
    session_id = "coord_#{System.unique_integer([:positive])}"

    tasks =
      for i <- 1..6 do
        Task.async(fn ->
          {:ok, result} =
            Snakepit.execute_in_session(session_id, "add", %{
              a: i,
              b: i * 10
            })

          {i, result}
        end)
      end

    results = Task.await_many(tasks, 10_000)
    IO.puts("  Completed #{length(results)} concurrent operations")

    # Verify all used same session
    all_results = Enum.map(results, fn {_i, result} -> result end)
    IO.puts("  All operations completed successfully: #{length(all_results) == 6}")
  end

  defp session_workflow_example do
    # Demonstrate a realistic session-based workflow
    session_id = "workflow_#{System.unique_integer([:positive])}"

    # Step 1: Initialize
    {:ok, _} = Snakepit.execute_in_session(session_id, "ping", %{})
    IO.puts("  ✓ Session initialized")

    # Step 2: Process data in chunks
    chunks = [1..10, 11..20, 21..30]

    results =
      Enum.map(chunks, fn chunk ->
        values = Enum.to_list(chunk)
        sum = Enum.sum(values)

        {:ok, result} =
          Snakepit.execute_in_session(session_id, "echo", %{
            chunk: values,
            sum: sum
          })

        result
      end)

    IO.puts("  ✓ Processed #{length(results)} chunks")

    # Step 3: Aggregate results
    {:ok, final} =
      Snakepit.execute_in_session(session_id, "echo", %{
        total_chunks: length(results),
        status: "complete"
      })

    IO.puts("  ✓ Workflow complete: #{inspect(final)}")
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  AdvancedExample.run()
end)
