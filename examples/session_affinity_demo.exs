#!/usr/bin/env elixir

# Session Affinity Demo - Demonstrates session-based worker affinity
# Shows how snakepit maintains worker affinity for session continuity

Mix.install([
  {:snakepit, path: ".."}
])

defmodule SessionAffinityDemo do
  @moduledoc """
  Demonstrates Snakepit session affinity features:
  - Multiple sessions with different workers
  - Session-based worker selection
  - Session context enhancement
  - Concurrent session management
  """

  require Logger

  def run do
    Logger.info("🔗 Starting Session Affinity Demo")
    
    Application.ensure_all_started(:snakepit)
    
    case Snakepit.Pool.await_ready(5_000) do
      :ok -> Logger.info("✅ Pool ready with session affinity support")
      {:error, :timeout} -> 
        Logger.error("❌ Pool initialization timeout")
        System.halt(1)
    end

    demo_multiple_sessions()
    demo_session_enhanced_adapter()
    demo_concurrent_sessions()

    Logger.info("🎉 Session Affinity Demo completed!")
  end

  defp demo_multiple_sessions do
    Logger.info("\n👥 Demo 1: Multiple Independent Sessions")
    
    # Create multiple sessions
    sessions = for i <- 1..3 do
      "session_#{i}_#{System.unique_integer([:positive])}"
    end
    
    # Execute commands in each session
    for session_id <- sessions do
      {:ok, result} = Snakepit.execute_in_session(
        session_id, 
        "get_session_info", 
        %{request_id: "info_#{System.unique_integer()}"}
      )
      Logger.info("Session #{session_id}: #{inspect(result)}")
    end
    
    # Show that sessions maintain affinity
    Logger.info("\n🔄 Demonstrating session persistence...")
    for session_id <- sessions do
      for iteration <- 1..2 do
        {:ok, result} = Snakepit.execute_in_session(
          session_id,
          "get_session_info", 
          %{iteration: iteration}
        )
        Logger.info("Session #{session_id} iteration #{iteration}: #{inspect(result)}")
      end
    end
  end

  defp demo_session_enhanced_adapter do
    Logger.info("\n✨ Demo 2: Session Context Enhancement")
    
    session_id = "enhanced_session_#{System.unique_integer([:positive])}"
    
    # Use SessionHelpers for enhanced context
    {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
      session_id,
      "store_data",
      %{"data" => "important_value", "type" => "user_preference"}
    )
    Logger.info("Enhanced session storage: #{inspect(result)}")
    
    # Retrieve in same session context
    {:ok, result} = Snakepit.SessionHelpers.execute_in_context(
      session_id,
      "get_session_info",
      %{"include_stored" => true}
    )
    Logger.info("Enhanced session retrieval: #{inspect(result)}")
  end

  defp demo_concurrent_sessions do
    Logger.info("\n⚡ Demo 3: Concurrent Session Management")
    
    # Start multiple concurrent sessions
    tasks = for i <- 1..5 do
      Task.async(fn ->
        session_id = "concurrent_session_#{i}_#{System.unique_integer()}"
        
        # Each task performs multiple operations in its session
        results = for op <- 1..3 do
          {:ok, result} = Snakepit.execute_in_session(
            session_id,
            "ping",
            %{session: session_id, operation: op, worker_check: true}
          )
          result
        end
        
        {session_id, results}
      end)
    end
    
    # Collect all results
    concurrent_results = Task.await_many(tasks, 10_000)
    
    for {session_id, results} <- concurrent_results do
      Logger.info("Concurrent session #{session_id}: #{length(results)} operations completed")
      Logger.debug("Results: #{inspect(results)}")
    end
    
    Logger.info("✅ All concurrent sessions completed successfully")
  end
end

# Configuration optimized for session affinity testing
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.SessionAffinityAdapter)
Application.put_env(:snakepit, :pool_config, %{pool_size: 3})  # Multiple workers for affinity demo

# Run the demo
SessionAffinityDemo.run()