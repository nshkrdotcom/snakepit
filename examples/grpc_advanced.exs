#!/usr/bin/env elixir

# Advanced gRPC Features Example
# Demonstrates complex workflows, pipelines, and integration patterns

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 4})
Application.put_env(:snakepit, :grpc_port, 50051)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"}
])

# Start the Snakepit application
{:ok, _} = Application.ensure_all_started(:snakepit)

defmodule AdvancedExample do
  def run do
    IO.puts("\n=== Advanced gRPC Features Example ===\n")
    
    # 1. Pipeline execution
    IO.puts("1. Pipeline execution:")
    pipeline_example()
    
    Process.sleep(500)
    
    # 2. Complex workflow with state
    IO.puts("\n2. Complex workflow with state management:")
    workflow_example()
    
    Process.sleep(500)
    
    # 3. Error recovery and retry logic
    IO.puts("\n3. Error recovery and retry:")
    error_recovery_example()
    
    Process.sleep(500)
    
    # 4. Event-driven processing
    IO.puts("\n4. Event-driven processing:")
    event_processing_example()
    
    Process.sleep(500)
    
    # 5. Resource management
    IO.puts("\n5. Resource management:")
    resource_management_example()
  end
  
  defp pipeline_example do
    session_id = "pipeline_#{System.unique_integer([:positive])}"
    
    # Define pipeline stages
    stages = [
      {1, "validate_input", %{schema: "user_data"}},
      {2, "transform_data", %{format: "normalized"}},
      {3, "enrich_data", %{sources: ["geo", "demographics"]}},
      {4, "analyze_data", %{algorithms: ["clustering", "classification"]}},
      {5, "generate_report", %{format: "json"}}
    ]
    
    # Execute pipeline
    results = Enum.reduce(stages, %{input: %{user_id: 123, name: "Test User"}}, fn {stage_num, operation, params}, acc ->
      IO.puts("  Stage #{stage_num}: #{operation}")
      
      case Snakepit.execute_in_session(session_id, operation, Map.merge(params, acc)) do
        {:ok, result} ->
          IO.puts("    ✓ Completed: #{result["status"] || "success"}")
          Map.merge(acc, result)
        
        {:error, reason} ->
          IO.puts("    ✗ Failed: #{inspect(reason)}")
          Map.put(acc, :error, reason)
      end
    end)
    
    IO.puts("  Pipeline result: #{inspect(Map.take(results, [:status, :error]))}")
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup_session", %{delete_all: true})
  end
  
  defp workflow_example do
    session_id = "workflow_#{System.unique_integer([:positive])}"
    
    # Initialize workflow state
    {:ok, _} = Snakepit.execute_in_session(session_id, "initialize_session", %{})
    
    # Register workflow variables
    workflow_vars = [
      %{name: "workflow_state", type: "choice", initial_value: "started",
        constraints: %{choices: ["started", "processing", "completed", "failed"]}},
      %{name: "processed_items", type: "integer", initial_value: 0},
      %{name: "errors", type: "integer", initial_value: 0},
      %{name: "results", type: "string", initial_value: "[]"}
    ]
    
    for var <- workflow_vars do
      {:ok, _} = Snakepit.execute_in_session(session_id, "register_variable", var)
    end
    
    # Simulate workflow execution
    items = Enum.to_list(1..10)
    
    # Update state to processing
    {:ok, _} = Snakepit.execute_in_session(session_id, "set_variable", %{
      name: "workflow_state",
      value: "processing"
    })
    
    # Process items with error simulation
    processed_results = Enum.map(items, fn item ->
      # Simulate 20% error rate
      if :rand.uniform() > 0.8 do
        {:ok, _} = Snakepit.execute_in_session(session_id, "set_variable", %{
          name: "errors",
          value: item  # Just for demo, normally would increment
        })
        {:error, "Failed to process item #{item}"}
      else
        {:ok, _} = Snakepit.execute_in_session(session_id, "set_variable", %{
          name: "processed_items",
          value: item
        })
        {:ok, "Processed item #{item}"}
      end
    end)
    
    # Get final state
    {:ok, state_vars} = Snakepit.execute_in_session(session_id, "get_variables", %{
      names: ["workflow_state", "processed_items", "errors"]
    })
    
    IO.puts("  Workflow completed:")
    Enum.each(state_vars["variables"], fn var ->
      IO.puts("    #{var["name"]}: #{var["value"]}")
    end)
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup_session", %{delete_all: true})
  end
  
  defp error_recovery_example do
    retry_with_backoff = fn operation, args, max_retries ->
      Enum.reduce_while(1..max_retries, {:error, :not_attempted}, fn attempt, _acc ->
        backoff = :math.pow(2, attempt - 1) * 100 |> round()
        
        IO.puts("  Attempt #{attempt}/#{max_retries} (backoff: #{backoff}ms)")
        
        case Snakepit.execute(operation, Map.put(args, :attempt, attempt)) do
          {:ok, result} ->
            IO.puts("    ✓ Success on attempt #{attempt}")
            {:halt, {:ok, result}}
          
          {:error, reason} ->
            IO.puts("    ✗ Failed: #{inspect(reason)}")
            if attempt < max_retries do
              Process.sleep(backoff)
              {:cont, {:error, reason}}
            else
              {:halt, {:error, :max_retries_exceeded}}
            end
        end
      end)
    end
    
    # Simulate operation that fails first 2 times
    result = retry_with_backoff.("flaky_operation", %{
      fail_until_attempt: 3
    }, 5)
    
    IO.puts("  Final result: #{inspect(result)}")
  end
  
  defp event_processing_example do
    session_id = "events_#{System.unique_integer([:positive])}"
    
    # Initialize event processing session
    {:ok, _} = Snakepit.execute_in_session(session_id, "initialize_session", %{})
    
    # Register event queue
    {:ok, _} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "event_queue",
      type: "string",
      initial_value: "[]"
    })
    
    # Event types
    events = [
      %{type: "user_login", user_id: 1, timestamp: DateTime.utc_now()},
      %{type: "page_view", user_id: 1, page: "/home", timestamp: DateTime.utc_now()},
      %{type: "button_click", user_id: 1, button: "subscribe", timestamp: DateTime.utc_now()},
      %{type: "user_logout", user_id: 1, timestamp: DateTime.utc_now()}
    ]
    
    # Process events
    for event <- events do
      IO.puts("  Processing event: #{event.type}")
      
      # Route to appropriate handler based on event type
      handler = case event.type do
        "user_login" -> "handle_login"
        "page_view" -> "handle_page_view"
        "button_click" -> "handle_interaction"
        "user_logout" -> "handle_logout"
        _ -> "handle_unknown"
      end
      
      {:ok, result} = Snakepit.execute_in_session(session_id, handler, event)
      IO.puts("    Handler result: #{result["status"] || "processed"}")
    end
    
    # Get processed events summary
    {:ok, summary} = Snakepit.execute_in_session(session_id, "get_event_summary", %{})
    IO.puts("  Events processed: #{summary["total_events"] || length(events)}")
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup_session", %{delete_all: true})
  end
  
  defp resource_management_example do
    session_id = "resources_#{System.unique_integer([:positive])}"
    
    # Initialize resource manager
    {:ok, _} = Snakepit.execute_in_session(session_id, "initialize_session", %{})
    
    # Register resource pool
    {:ok, _} = Snakepit.execute_in_session(session_id, "register_variable", %{
      name: "connection_pool",
      type: "integer",
      initial_value: 10,
      constraints: %{min: 0, max: 10},
      metadata: %{resource_type: "database_connections"}
    })
    
    # Simulate resource allocation and release
    tasks = for i <- 1..15 do
      Task.async(fn ->
        # Try to acquire resource
        case Snakepit.execute_in_session(session_id, "acquire_resource", %{
          resource_type: "connection",
          timeout: 2000
        }) do
          {:ok, resource} ->
            IO.puts("  Task #{i}: Acquired resource #{resource["resource_id"]}")
            
            # Simulate work
            Process.sleep(:rand.uniform(500))
            
            # Release resource
            {:ok, _} = Snakepit.execute_in_session(session_id, "release_resource", %{
              resource_id: resource["resource_id"]
            })
            IO.puts("  Task #{i}: Released resource")
            :ok
          
          {:error, :timeout} ->
            IO.puts("  Task #{i}: Failed to acquire resource (timeout)")
            :timeout
        end
      end)
    end
    
    results = Task.await_many(tasks, 10_000)
    
    successful = Enum.count(results, &(&1 == :ok))
    timeouts = Enum.count(results, &(&1 == :timeout))
    
    IO.puts("  Resource allocation results:")
    IO.puts("    Successful: #{successful}")
    IO.puts("    Timeouts: #{timeouts}")
    
    # Cleanup
    Snakepit.execute_in_session(session_id, "cleanup_session", %{delete_all: true})
  end
end

# Run the example
AdvancedExample.run()

# Allow time for operations to complete
Process.sleep(2000)

# Graceful shutdown
IO.puts("\nShutting down...")
Application.stop(:snakepit)