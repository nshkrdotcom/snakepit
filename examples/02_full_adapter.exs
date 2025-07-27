#!/usr/bin/env elixir

# Example 02: Full Adapter Implementation
# 
# This example shows an adapter implementing ALL callbacks from the behavior,
# including optional ones for initialization, cleanup, and streaming.

defmodule FullAdapter do
  @moduledoc """
  A complete adapter implementation showing all Snakepit.Adapter callbacks.
  
  This demonstrates:
  - Required execute/3 callback
  - Optional init/1 and terminate/2 for lifecycle
  - Optional start_worker/2 for custom worker processes
  - Optional streaming support
  - Optional cognitive metadata
  """
  
  @behaviour Snakepit.Adapter
  require Logger
  
  # Required callback
  @impl Snakepit.Adapter
  def execute(command, args, opts) do
    worker_pid = Keyword.get(opts, :worker_pid)
    Logger.debug("Executing #{command} on worker #{inspect(worker_pid)}")
    
    case command do
      "ping" ->
        {:ok, "pong from FullAdapter"}
        
      "get_config" ->
        # Access adapter state through worker
        {:ok, %{adapter: "FullAdapter", initialized: true}}
        
      "process_data" ->
        data = Map.get(args, "data", [])
        processed = Enum.map(data, &(&1 * 2))
        {:ok, processed}
        
      _ ->
        {:ok, %{command: command, args: args, adapter: "FullAdapter"}}
    end
  end
  
  # Optional: Initialize adapter with configuration
  @impl Snakepit.Adapter
  def init(config) do
    Logger.info("FullAdapter initializing with config: #{inspect(config)}")
    
    state = %{
      initialized_at: DateTime.utc_now(),
      config: config,
      custom_setting: Keyword.get(config, :custom_setting, "default"),
      metrics: %{
        total_requests: 0,
        errors: 0
      }
    }
    
    {:ok, state}
  end
  
  # Optional: Cleanup on termination
  @impl Snakepit.Adapter
  def terminate(reason, state) do
    Logger.info("FullAdapter terminating: #{inspect(reason)}")
    Logger.info("Final metrics: #{inspect(state.metrics)}")
    :ok
  end
  
  # Optional: Custom worker startup
  @impl Snakepit.Adapter
  def start_worker(adapter_state, worker_id) do
    Logger.info("Starting custom worker: #{worker_id}")
    
    # For this example, we'll use a simple process
    # In real adapters, this might start external processes
    pid = spawn_link(fn ->
      worker_loop(worker_id, adapter_state)
    end)
    
    {:ok, pid}
  end
  
  # Optional: Streaming support
  @impl Snakepit.Adapter
  def supports_streaming?(), do: true
  
  @impl Snakepit.Adapter
  def execute_stream(command, args, callback, _opts) do
    Logger.info("Streaming command: #{command}")
    
    case command do
      "count_stream" ->
        max = Map.get(args, "max", 5)
        for i <- 1..max do
          callback.(%{number: i, progress: i/max * 100})
          Process.sleep(100)
        end
        :ok
        
      "data_stream" ->
        data = Map.get(args, "data", ["a", "b", "c"])
        for {item, index} <- Enum.with_index(data) do
          callback.(%{
            item: item,
            index: index,
            timestamp: DateTime.utc_now()
          })
          Process.sleep(50)
        end
        :ok
        
      _ ->
        {:error, "Streaming not supported for command: #{command}"}
    end
  end
  
  # Optional: Cognitive metadata for optimization
  @impl Snakepit.Adapter
  def get_cognitive_metadata() do
    %{
      cognitive_capabilities: [:pattern_learning, :performance_tracking],
      performance_characteristics: %{
        typical_latency_ms: 10,
        throughput_ops_per_sec: 1000,
        resource_intensity: :low
      },
      resource_requirements: %{
        memory_mb: 50,
        cpu_usage: :low,
        network_usage: :none
      },
      optimization_hints: [
        :supports_batching,
        :benefits_from_caching,
        :low_latency,
        :stateless_operations
      ]
    }
  end
  
  # Optional: Accept performance feedback
  @impl Snakepit.Adapter
  def report_performance_metrics(metrics, context) do
    Logger.info("Performance metrics received: #{inspect(metrics)}")
    Logger.debug("Context: #{inspect(context)}")
    :ok
  end
  
  # Private helper for worker process
  defp worker_loop(worker_id, adapter_state) do
    receive do
      :stop -> 
        Logger.debug("Worker #{worker_id} stopping")
        :ok
      msg ->
        Logger.debug("Worker #{worker_id} received: #{inspect(msg)}")
        worker_loop(worker_id, adapter_state)
    end
  end
end

# Configure with custom settings
Application.put_env(:snakepit, :adapter_module, FullAdapter)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :adapter_config, [
  custom_setting: "example_value",
  debug_mode: true
])

# Enable debug logging to see adapter lifecycle
Logger.configure(level: :info)

# Use run_as_script for proper cleanup
Snakepit.run_as_script(fn ->
  IO.puts("\n=== Full Adapter Example ===\n")
  
  # The adapter's init/1 was called when the pool started
  
  # Example 1: Basic execution
  IO.puts("1. Basic command:")
  {:ok, result} = Snakepit.execute("ping", %{})
  IO.puts("   Result: #{result}")
  
  # Example 2: Access adapter configuration
  IO.puts("\n2. Get adapter config:")
  {:ok, config} = Snakepit.execute("get_config", %{})
  IO.inspect(config, label: "   Config")
  
  # Example 3: Process data
  IO.puts("\n3. Process data:")
  {:ok, processed} = Snakepit.execute("process_data", %{"data" => [1, 2, 3, 4, 5]})
  IO.puts("   Doubled: #{inspect(processed)}")
  
  # Example 4: Streaming execution
  IO.puts("\n4. Streaming count:")
  Snakepit.execute_stream("count_stream", %{"max" => 3}, fn chunk ->
    IO.puts("   Received: #{inspect(chunk)}")
  end)
  
  # Example 5: Streaming with data
  IO.puts("\n5. Streaming data:")
  Snakepit.execute_stream("data_stream", %{"data" => ["hello", "world"]}, fn chunk ->
    IO.puts("   Stream chunk: #{inspect(chunk)}")
  end)
  
  # Example 6: Get cognitive metadata
  IO.puts("\n6. Cognitive metadata:")
  metadata = FullAdapter.get_cognitive_metadata()
  IO.inspect(metadata, label: "   Metadata", pretty: true)
  
  # Example 7: Report performance metrics
  IO.puts("\n7. Reporting performance metrics:")
  FullAdapter.report_performance_metrics(
    %{latency_ms: 5, success: true},
    %{command: "ping", timestamp: DateTime.utc_now()}
  )
  IO.puts("   Metrics reported successfully")
  
  IO.puts("\n=== Example completed! ===")
  IO.puts("Note: Check logs to see init/terminate lifecycle callbacks")
  
  # The adapter's terminate/2 will be called when the script exits
end)

# Key Concepts Demonstrated:
#
# 1. FULL BEHAVIOR: All callbacks implemented (required + optional)
# 2. LIFECYCLE: init/1 called on startup, terminate/2 on shutdown
# 3. STREAMING: Native streaming support with callbacks
# 4. COGNITIVE READY: Metadata and metrics for future optimization
# 5. CUSTOM WORKERS: Adapter can control worker process creation
# 6. STATEFUL: Adapter state initialized and available throughout