defmodule SnakepitShowcase.Demo.Runner do
  @moduledoc """
  Executes demos with automatic resource tracking and cleanup.
  
  The runner ensures that all resources created during a demo are properly
  cleaned up, even if the demo fails or crashes.
  """
  
  require Logger
  alias SnakepitShowcase.Demo.ResourceTracker
  
  @doc """
  Executes a demo module with automatic cleanup.
  
  Options:
    * `:silent` - Suppress output (default: false)
    * `:stop_on_error` - Stop execution on first error (default: false)
  """
  def execute(demo_module, opts \\ []) do
    silent = Keyword.get(opts, :silent, false)
    stop_on_error = Keyword.get(opts, :stop_on_error, false)
    
    # Start resource tracker
    {:ok, tracker} = ResourceTracker.start_link()
    
    # Build execution context
    context = %{
      tracker: tracker,
      demo_module: demo_module,
      started_at: System.monotonic_time(),
      silent: silent,
      opts: opts,
      step_results: %{}
    }
    
    try do
      unless silent do
        Logger.info("Starting demo: #{demo_module.description()}")
        Logger.info("")
      end
      
      # Execute each step
      results = 
        demo_module.steps()
        |> Enum.reduce_while([], fn {step_name, description}, acc ->
          unless silent do
            Logger.info("  → #{description}")
          end
          
          case execute_step(demo_module, step_name, context) do
            {:ok, result} ->
              unless silent do
                Logger.info("    ✓ Completed")
              end
              
              # Update context with step result
              context = put_in(context.step_results[step_name], result)
              {:cont, [{:ok, {step_name, result}} | acc]}
              
            {:error, reason} = error ->
              unless silent do
                Logger.error("    ✗ Failed: #{inspect(reason)}")
              end
              
              if stop_on_error do
                {:halt, [error | acc]}
              else
                {:cont, [error | acc]}
              end
          end
        end)
        |> Enum.reverse()
      
      # Determine overall result
      if Enum.all?(results, &match?({:ok, _}, &1)) do
        unless silent do
          Logger.info("")
          Logger.info("Demo completed successfully!")
        end
        :ok
      else
        errors = Enum.filter(results, &match?({:error, _}, &1))
        {:error, {:demo_failed, errors}}
      end
      
    rescue
      error ->
        Logger.error("Demo crashed: #{inspect(error)}")
        Logger.error(Exception.format_stacktrace())
        {:error, {:demo_crashed, error}}
        
    after
      # Always cleanup
      cleanup_demo(demo_module, context, tracker)
      ResourceTracker.stop(tracker)
    end
  end
  
  defp execute_step(demo_module, step_name, context) do
    try do
      demo_module.run_step(step_name, context)
    rescue
      error ->
        {:error, {:step_crashed, error, __STACKTRACE__}}
    end
  end
  
  defp cleanup_demo(demo_module, context, tracker) do
    Logger.info("")
    Logger.info("Cleaning up demo resources...")
    
    # Call demo's custom cleanup if defined
    if function_exported?(demo_module, :cleanup, 1) do
      try do
        demo_module.cleanup(context)
      rescue
        error ->
          Logger.error("Demo cleanup failed: #{inspect(error)}")
      end
    end
    
    # Get tracked resources
    resources = ResourceTracker.get_all(tracker)
    
    # Clean up sessions
    if resources.sessions != [] do
      Logger.info("  Cleaning up #{length(resources.sessions)} sessions...")
      Enum.each(resources.sessions, &cleanup_session/1)
    end
    
    # Clean up other resources
    Enum.each(resources.resources, fn {type, id} ->
      Logger.info("  Cleaning up #{type}: #{inspect(id)}")
      cleanup_resource(type, id)
    end)
    
    Logger.info("  ✓ Cleanup completed")
  end
  
  defp cleanup_session(session_id) do
    # Use Snakepit's session cleanup if available
    # For now, we'll attempt a cleanup command
    try do
      case Snakepit.execute_in_session(session_id, "cleanup", %{}) do
        {:ok, _} -> :ok
        {:error, reason} -> 
          Logger.debug("Session cleanup failed: #{inspect(reason)}")
      end
    rescue
      _ -> :ok
    end
  end
  
  defp cleanup_resource(:process, pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end
  
  defp cleanup_resource(:file, path) do
    File.rm(path)
  end
  
  defp cleanup_resource(:port, port) when is_port(port) do
    Port.close(port)
  end
  
  defp cleanup_resource(type, id) do
    Logger.warn("Unknown resource type for cleanup: #{type} - #{inspect(id)}")
  end
end