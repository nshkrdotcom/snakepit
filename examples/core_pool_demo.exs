#!/usr/bin/env elixir

# Core Pool Demo - Working Example of Snakepit Core Functionality
# This demonstrates the basic pool and session functionality available in snakepit core

Mix.install([
  {:snakepit, path: ".."}
])

defmodule CorePoolDemo do
  @moduledoc """
  Demonstrates core Snakepit functionality:
  - Pool initialization and management
  - Basic command execution
  - Session-based worker affinity
  - Mock adapter usage
  """

  require Logger

  def run do
    Logger.info("🚀 Starting Core Pool Demo")
    
    # Ensure application is started
    Application.ensure_all_started(:snakepit)
    
    # Wait for pool to initialize
    case Snakepit.Pool.await_ready(5_000) do
      :ok -> Logger.info("✅ Pool ready")
      {:error, :timeout} -> 
        Logger.error("❌ Pool initialization timeout")
        System.halt(1)
    end

    demo_basic_execution()
    demo_session_affinity() 
    demo_pool_statistics()
    demo_streaming_if_supported()

    Logger.info("🎉 Core Pool Demo completed successfully!")
  end

  defp demo_basic_execution do
    Logger.info("\n📋 Demo 1: Basic Pool Execution")
    
    # Execute basic commands
    {:ok, result} = Snakepit.execute("ping", %{})
    Logger.info("Ping result: #{inspect(result)}")
    
    {:ok, result} = Snakepit.execute("echo", %{"message" => "Hello from pool!"})
    Logger.info("Echo result: #{inspect(result)}")
    
    # Test error handling
    {:error, error} = Snakepit.execute("error", %{})
    Logger.info("Error handling: #{inspect(error)}")
  end

  defp demo_session_affinity do
    Logger.info("\n🔗 Demo 2: Session-Based Worker Affinity")
    
    session_id = "demo_session_#{System.unique_integer([:positive])}"
    
    # Execute multiple commands in the same session
    for i <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "ping", %{iteration: i})
      Logger.info("Session #{session_id}, iteration #{i}: #{inspect(result)}")
      Process.sleep(100)
    end
    
    # Use session helpers for enhanced functionality
    {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
      session_id, 
      "echo", 
      %{"message" => "Enhanced session execution"}
    )
    Logger.info("Enhanced session result: #{inspect(result)}")
  end

  defp demo_pool_statistics do
    Logger.info("\n📊 Demo 3: Pool Statistics and Management")
    
    stats = Snakepit.get_stats()
    Logger.info("Pool stats: #{inspect(stats, pretty: true)}")
    
    workers = Snakepit.list_workers()
    Logger.info("Active workers: #{inspect(workers)}")
  end

  defp demo_streaming_if_supported do
    Logger.info("\n🌊 Demo 4: Streaming (if adapter supports it)")
    
    adapter = Application.get_env(:snakepit, :adapter_module)
    
    if adapter && function_exported?(adapter, :supports_streaming?, 0) && adapter.supports_streaming?() do
      Logger.info("Adapter supports streaming, testing...")
      
      result = Snakepit.execute_stream("streaming_test", %{count: 3}, fn chunk ->
        Logger.info("Received stream chunk: #{inspect(chunk)}")
      end)
      
      Logger.info("Streaming result: #{inspect(result)}")
    else
      Logger.info("Adapter does not support streaming (this is normal for mock adapters)")
    end
  end
end

# Configuration for this demo
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 2})

# Run the demo
CorePoolDemo.run()