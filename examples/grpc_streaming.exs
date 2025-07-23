#!/usr/bin/env elixir

# Streaming with gRPC Example
# Demonstrates real-time streaming operations with progress tracking

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

defmodule StreamingExample do
  def run do
    IO.puts("\n=== Streaming gRPC Example ===\n")
    
    # 1. Simple streaming operation
    IO.puts("1. Simple streaming with progress:")
    Snakepit.execute_stream("process_batch", %{
      items: ["item1", "item2", "item3", "item4", "item5"],
      delay_ms: 200
    }, fn chunk ->
      IO.puts("  Progress: #{chunk["progress"]}% - Processing: #{chunk["current_item"]}")
    end)
    
    Process.sleep(100)
    
    # 2. Streaming with accumulation
    IO.puts("\n2. Streaming with result accumulation:")
    results = []
    
    Snakepit.execute_stream("analyze_data", %{
      data_points: Enum.to_list(1..10),
      chunk_size: 3
    }, fn chunk ->
      IO.puts("  Chunk #{chunk["chunk_number"]}: #{inspect(chunk["results"])}")
      results ++ chunk["results"]
    end)
    
    Process.sleep(100)
    
    # 3. Streaming with error handling
    IO.puts("\n3. Streaming with error handling:")
    Snakepit.execute_stream("risky_operation", %{
      operations: ["safe1", "safe2", "danger", "safe3"],
      fail_on: "danger"
    }, fn chunk ->
      case chunk do
        %{"error" => error} ->
          IO.puts("  ⚠️  Error occurred: #{error}")
        %{"status" => "success", "item" => item} ->
          IO.puts("  ✓ Processed: #{item}")
        _ ->
          IO.puts("  Received: #{inspect(chunk)}")
      end
    end)
    
    Process.sleep(100)
    
    # 4. Large dataset streaming simulation
    IO.puts("\n4. Large dataset streaming:")
    total_items = 1000
    processed = 0
    
    start_time = System.monotonic_time(:millisecond)
    
    Snakepit.execute_stream("process_large_dataset", %{
      total_items: total_items,
      batch_size: 100,
      simulate_work: true
    }, fn chunk ->
      processed = processed + chunk["items_in_batch"]
      elapsed = System.monotonic_time(:millisecond) - start_time
      rate = if elapsed > 0, do: Float.round(processed * 1000 / elapsed, 1), else: 0
      
      IO.puts("  Batch #{chunk["batch_number"]}/#{chunk["total_batches"]} - " <>
              "Progress: #{chunk["progress"]}% - " <>
              "Rate: #{rate} items/sec")
    end)
    
    # 5. Parallel streaming operations
    IO.puts("\n5. Parallel streaming operations:")
    
    tasks = for i <- 1..3 do
      Task.async(fn ->
        Snakepit.execute_stream("parallel_stream", %{
          stream_id: i,
          items: Enum.to_list(1..5)
        }, fn chunk ->
          IO.puts("  Stream #{i}: #{chunk["message"]}")
        end)
      end)
    end
    
    Task.await_many(tasks, 10_000)
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  StreamingExample.run()
end)
