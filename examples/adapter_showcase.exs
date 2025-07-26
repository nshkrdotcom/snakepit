#!/usr/bin/env elixir

# Adapter Showcase - Demonstrates different adapter types and capabilities
# Shows how snakepit works with different adapter implementations

Mix.install([
  {:snakepit, path: ".."}
])

defmodule AdapterShowcase do
  @moduledoc """
  Showcases different Snakepit adapter implementations:
  - Basic mock adapter
  - gRPC-style mock adapter  
  - Failing adapter (error handling)
  - Session affinity adapter
  - Adapter validation and metadata
  """

  require Logger

  def run do
    Logger.info("🎭 Starting Adapter Showcase")
    
    demo_basic_adapter()
    demo_grpc_adapter()
    demo_error_handling()
    demo_adapter_validation()
    demo_adapter_metadata()

    Logger.info("🎉 Adapter Showcase completed!")
  end

  defp demo_basic_adapter do
    Logger.info("\n🔧 Demo 1: Basic Mock Adapter")
    
    # Start pool with basic adapter
    start_pool_with_adapter(Snakepit.TestAdapters.MockAdapter, :basic_pool)
    
    # Test basic functionality
    {:ok, result} = Snakepit.Pool.execute("ping", %{}, pool: :basic_pool)
    Logger.info("Basic adapter ping: #{inspect(result)}")
    
    {:ok, result} = Snakepit.Pool.execute("echo", %{"message" => "Hello!"}, pool: :basic_pool)
    Logger.info("Basic adapter echo: #{inspect(result)}")
    
    # Test slow operation
    start_time = System.monotonic_time(:millisecond)
    {:ok, result} = Snakepit.Pool.execute("slow", %{}, pool: :basic_pool)
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Slow operation completed in #{duration}ms: #{inspect(result)}")
    
    stop_pool(:basic_pool)
  end

  defp demo_grpc_adapter do
    Logger.info("\n🌐 Demo 2: gRPC-Style Mock Adapter")
    
    start_pool_with_adapter(Snakepit.TestAdapters.MockGRPCAdapter, :grpc_pool)
    
    # Test gRPC-style operations
    {:ok, result} = Snakepit.Pool.execute("create_program", %{
      signature: "input -> output",
      program_type: "predict"
    }, pool: :grpc_pool)
    Logger.info("Program creation: #{inspect(result)}")
    
    program_id = result[:program_id] || "mock_program"
    
    {:ok, result} = Snakepit.Pool.execute("execute_program", %{
      program_id: program_id,
      input_data: %{query: "test query"}
    }, pool: :grpc_pool)
    Logger.info("Program execution: #{inspect(result)}")
    
    {:ok, result} = Snakepit.Pool.execute("discover_schema", %{}, pool: :grpc_pool)
    Logger.info("Schema discovery: #{inspect(result)}")
    
    stop_pool(:grpc_pool)
  end

  defp demo_error_handling do
    Logger.info("\n⚠️  Demo 3: Error Handling and Resilience")
    
    start_pool_with_adapter(Snakepit.TestAdapters.MockAdapter, :error_pool)
    
    # Test error handling
    {:error, error} = Snakepit.Pool.execute("error", %{}, pool: :error_pool)
    Logger.info("Expected error handling: #{inspect(error)}")
    
    # Verify pool still works after error
    {:ok, result} = Snakepit.Pool.execute("ping", %{}, pool: :error_pool)
    Logger.info("Pool recovery after error: #{inspect(result)}")
    
    stop_pool(:error_pool)
    
    # Test failing adapter initialization
    Logger.info("\n💥 Testing failing adapter...")
    case start_pool_with_adapter(Snakepit.TestAdapters.FailingAdapter, :failing_pool, false) do
      {:error, reason} -> 
        Logger.info("Expected failure during adapter init: #{inspect(reason)}")
      {:ok, _} ->
        Logger.error("Unexpected success with failing adapter")
        stop_pool(:failing_pool)
    end
  end

  defp demo_adapter_validation do
    Logger.info("\n✅ Demo 4: Adapter Validation")
    
    adapters_to_test = [
      Snakepit.TestAdapters.MockAdapter,
      Snakepit.TestAdapters.MockGRPCAdapter,
      Snakepit.TestAdapters.SessionAffinityAdapter,
      Snakepit.TestAdapters.FailingAdapter
    ]
    
    for adapter <- adapters_to_test do
      validation_result = Snakepit.Adapter.validate_implementation(adapter)
      Logger.info("#{inspect(adapter)} validation: #{inspect(validation_result)}")
    end
  end

  defp demo_adapter_metadata do
    Logger.info("\n📋 Demo 5: Adapter Metadata and Capabilities")
    
    adapters_to_inspect = [
      Snakepit.TestAdapters.MockAdapter,
      Snakepit.TestAdapters.MockGRPCAdapter,
      Snakepit.TestAdapters.SessionAffinityAdapter
    ]
    
    for adapter <- adapters_to_inspect do
      if function_exported?(adapter, :get_cognitive_metadata, 0) do
        metadata = adapter.get_cognitive_metadata()
        Logger.info("#{inspect(adapter)} metadata:")
        Logger.info("  Type: #{metadata[:adapter_type]}")
        Logger.info("  Test mode: #{metadata[:test_mode]}")
        Logger.info("  Features: #{inspect(metadata[:mock_features] || metadata[:features])}")
        
        if function_exported?(adapter, :uses_grpc?, 0) do
          Logger.info("  Uses gRPC: #{adapter.uses_grpc?()}")
        end
        
        if function_exported?(adapter, :supports_streaming?, 0) do
          Logger.info("  Supports streaming: #{adapter.supports_streaming?()}")
        end
      else
        Logger.info("#{inspect(adapter)} does not provide metadata")
      end
      Logger.info("")
    end
  end

  defp start_pool_with_adapter(adapter_module, pool_name, expect_success \\ true) do
    pool_opts = [
      size: 2,
      adapter_module: adapter_module,
      worker_module: Snakepit.GenericWorker,
      name: pool_name
    ]
    
    result = Snakepit.Pool.start_link(pool_opts)
    
    case {result, expect_success} do
      {{:ok, _pid}, true} ->
        Snakepit.Pool.await_ready(pool_name, 5_000)
        Logger.info("✅ Started pool #{pool_name} with #{inspect(adapter_module)}")
        result
        
      {{:error, reason}, false} ->
        Logger.info("❌ Expected failure starting pool #{pool_name}: #{inspect(reason)}")
        result
        
      {{:ok, _pid}, false} ->
        Logger.warning("⚠️  Unexpected success starting pool #{pool_name}")
        result
        
      {{:error, reason}, true} ->
        Logger.error("❌ Unexpected failure starting pool #{pool_name}: #{inspect(reason)}")
        result
    end
  end

  defp stop_pool(pool_name) do
    if Process.whereis(pool_name) do
      GenServer.stop(pool_name)
      Logger.info("🛑 Stopped pool #{pool_name}")
    end
  end
end

# Run the showcase
AdapterShowcase.run()