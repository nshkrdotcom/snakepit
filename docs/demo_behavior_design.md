# Behavior-Based Demo Management for Snakepit

## Overview

This document proposes a behavior-based approach for managing Snakepit demos that ensures automatic cleanup and consistent structure across all demonstrations.

## Goals

1. **Automatic Cleanup**: Ensure all resources (sessions, processes, etc.) are cleaned up after demo execution
2. **Consistent Structure**: Provide a standard interface for all demos
3. **Error Resilience**: Handle failures gracefully without leaving orphaned resources
4. **Easy Development**: Make it simple to create new demos with guaranteed cleanup

## Proposed Architecture

### 1. Demo Behaviour Definition

```elixir
defmodule SnakepitShowcase.Demo do
  @moduledoc """
  Behaviour for implementing Snakepit demonstrations.
  
  Provides automatic resource tracking and cleanup through compile-time hooks.
  """
  
  @callback description() :: String.t()
  @callback steps() :: [step()]
  @callback run_step(step_name :: atom(), context :: map()) :: {:ok, result :: any()} | {:error, reason :: any()}
  
  @type step :: {atom(), String.t()}
  
  defmacro __using__(_opts) do
    quote do
      @behaviour SnakepitShowcase.Demo
      
      # Track resources at compile time
      Module.register_attribute(__MODULE__, :tracked_sessions, accumulate: true)
      Module.register_attribute(__MODULE__, :tracked_resources, accumulate: true)
      
      # Import helper functions
      import SnakepitShowcase.Demo.Helpers
      
      # Default run implementation
      def run do
        SnakepitShowcase.Demo.Runner.execute(__MODULE__)
      end
      
      # Hook for cleanup
      @before_compile SnakepitShowcase.Demo
    end
  end
  
  defmacro __before_compile__(env) do
    quote do
      def __demo_metadata__ do
        %{
          module: unquote(env.module),
          tracked_sessions: @tracked_sessions,
          tracked_resources: @tracked_resources
        }
      end
    end
  end
end
```

### 2. Demo Runner with Automatic Cleanup

```elixir
defmodule SnakepitShowcase.Demo.Runner do
  @moduledoc """
  Executes demos with automatic resource tracking and cleanup.
  """
  
  require Logger
  
  def execute(demo_module) do
    # Initialize tracking
    tracker = start_resource_tracker()
    
    try do
      # Run the demo with tracking context
      context = %{
        tracker: tracker,
        demo_module: demo_module,
        started_at: System.monotonic_time()
      }
      
      Logger.info("Starting demo: #{demo_module.description()}")
      
      # Execute each step
      results = for {step_name, description} <- demo_module.steps() do
        Logger.info("  Running step: #{description}")
        
        case demo_module.run_step(step_name, context) do
          {:ok, result} ->
            Logger.info("  ✓ Step completed: #{step_name}")
            {:ok, {step_name, result}}
            
          {:error, reason} = error ->
            Logger.error("  ✗ Step failed: #{step_name} - #{inspect(reason)}")
            error
        end
      end
      
      # Check if all steps succeeded
      if Enum.all?(results, &match?({:ok, _}, &1)) do
        :ok
      else
        {:error, :demo_failed}
      end
      
    after
      # Always cleanup, regardless of success/failure
      cleanup_resources(tracker)
      stop_resource_tracker(tracker)
    end
  end
  
  defp start_resource_tracker do
    {:ok, pid} = Agent.start_link(fn -> %{sessions: [], resources: []} end)
    pid
  end
  
  defp stop_resource_tracker(tracker) do
    Agent.stop(tracker)
  end
  
  defp cleanup_resources(tracker) do
    resources = Agent.get(tracker, & &1)
    
    Logger.info("Cleaning up demo resources...")
    
    # Clean up sessions
    for session_id <- resources.sessions do
      Logger.debug("  Cleaning up session: #{session_id}")
      # Call Snakepit session cleanup
      Snakepit.cleanup_session(session_id)
    end
    
    # Clean up other resources
    for {type, id} <- resources.resources do
      Logger.debug("  Cleaning up #{type}: #{id}")
      cleanup_resource(type, id)
    end
    
    Logger.info("Demo cleanup completed")
  end
  
  defp cleanup_resource(:process, pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end
  
  defp cleanup_resource(:file, path) do
    File.rm(path)
  end
  
  defp cleanup_resource(type, id) do
    Logger.warn("Unknown resource type for cleanup: #{type} - #{id}")
  end
end
```

### 3. Demo Helper Functions

```elixir
defmodule SnakepitShowcase.Demo.Helpers do
  @moduledoc """
  Helper functions for demos with automatic resource tracking.
  """
  
  def track_session(context, session_id) do
    Agent.update(context.tracker, fn state ->
      %{state | sessions: [session_id | state.sessions]}
    end)
    session_id
  end
  
  def track_resource(context, type, id) do
    Agent.update(context.tracker, fn state ->
      %{state | resources: [{type, id} | state.resources]}
    end)
    id
  end
  
  def with_session(context, session_id, fun) do
    track_session(context, session_id)
    
    try do
      fun.(session_id)
    rescue
      e ->
        {:error, e}
    end
  end
  
  def create_session(context, prefix \\ "demo") do
    session_id = "#{prefix}_#{System.unique_integer([:positive])}"
    track_session(context, session_id)
    session_id
  end
end
```

### 4. Example Demo Implementation

```elixir
defmodule SnakepitShowcase.Demos.BehaviorBasedDemo do
  use SnakepitShowcase.Demo
  
  @impl true
  def description do
    "Demonstrates the behavior-based demo system with automatic cleanup"
  end
  
  @impl true
  def steps do
    [
      {:create_session, "Create a new session"},
      {:perform_operations, "Perform stateful operations"},
      {:verify_state, "Verify session state"},
      {:simulate_error, "Simulate an error (cleanup still happens)"}
    ]
  end
  
  @impl true
  def run_step(:create_session, context) do
    session_id = create_session(context, "behavior_demo")
    
    {:ok, result} = Snakepit.execute_in_session(session_id, "init_session", %{
      demo_type: "behavior_based",
      timestamp: DateTime.utc_now()
    })
    
    {:ok, %{session_id: session_id, init_result: result}}
  end
  
  @impl true
  def run_step(:perform_operations, %{tracker: _} = context) do
    # Get session from previous step (would need to implement state passing)
    session_id = get_current_session(context)
    
    results = for i <- 1..5 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "increment_counter", %{
        amount: i
      })
      result
    end
    
    {:ok, results}
  end
  
  @impl true
  def run_step(:verify_state, context) do
    session_id = get_current_session(context)
    
    {:ok, state} = Snakepit.execute_in_session(session_id, "get_state", %{})
    
    if state["counter"] == 15 do  # 1+2+3+4+5
      {:ok, :verified}
    else
      {:error, :invalid_state}
    end
  end
  
  @impl true
  def run_step(:simulate_error, _context) do
    # This error will be caught, but cleanup will still happen
    {:error, :intentional_demo_error}
  end
  
  defp get_current_session(context) do
    # In a real implementation, we'd pass state between steps
    Agent.get(context.tracker, fn %{sessions: [session | _]} -> session end)
  end
end
```

### 5. Enhanced Demo Runner for Showcase

```elixir
defmodule SnakepitShowcase.EnhancedDemoRunner do
  @moduledoc """
  Enhanced demo runner that uses the behavior-based system.
  """
  
  @demos [
    {SnakepitShowcase.Demos.BehaviorBasedDemo, "Behavior-Based Demo"},
    # ... other demos
  ]
  
  def run_all do
    IO.puts("\n🎯 Snakepit Showcase - Running All Demos\n")
    
    # Initialize global cleanup tracker
    {:ok, global_tracker} = GlobalCleanupTracker.start_link()
    
    try do
      Enum.each(@demos, fn {module, name} ->
        run_single_demo(module, name, global_tracker)
      end)
    after
      # Final cleanup of any remaining resources
      GlobalCleanupTracker.cleanup_all(global_tracker)
      IO.puts("\n📛 Final Snakepit shutdown...")
      Application.stop(:snakepit)
    end
  end
  
  defp run_single_demo(module, name, global_tracker) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("📋 Demo: #{name}")
    IO.puts(String.duplicate("=", 60) <> "\n")
    
    # Register demo with global tracker
    GlobalCleanupTracker.register_demo(global_tracker, module)
    
    case module.run() do
      :ok -> 
        IO.puts("✅ #{name} completed successfully")
        
      {:error, reason} -> 
        IO.puts("❌ #{name} failed: #{inspect(reason)}")
    end
    
    # Demo-specific cleanup already happened in the behavior
    # Global tracker ensures nothing was missed
    GlobalCleanupTracker.verify_demo_cleanup(global_tracker, module)
  end
end
```

### 6. Global Cleanup Tracker

```elixir
defmodule SnakepitShowcase.GlobalCleanupTracker do
  @moduledoc """
  Tracks all resources across demos to ensure complete cleanup.
  """
  
  use GenServer
  
  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end
  
  def register_demo(tracker, demo_module) do
    GenServer.call(tracker, {:register_demo, demo_module})
  end
  
  def verify_demo_cleanup(tracker, demo_module) do
    GenServer.call(tracker, {:verify_cleanup, demo_module})
  end
  
  def cleanup_all(tracker) do
    GenServer.call(tracker, :cleanup_all)
  end
  
  # GenServer callbacks
  def init(_) do
    {:ok, %{
      demos: MapSet.new(),
      active_sessions: MapSet.new(),
      active_resources: []
    }}
  end
  
  def handle_call({:register_demo, demo_module}, _from, state) do
    # Could hook into the demo's resource tracking here
    {:reply, :ok, %{state | demos: MapSet.put(state.demos, demo_module)}}
  end
  
  def handle_call({:verify_cleanup, _demo_module}, _from, state) do
    # Verify all resources from this demo are cleaned up
    # Could cross-reference with Snakepit's internal state
    {:reply, :ok, state}
  end
  
  def handle_call(:cleanup_all, _from, state) do
    # Final sweep to clean up any remaining resources
    Logger.info("Global cleanup: checking for remaining resources...")
    
    # Could query Snakepit for active sessions and clean them up
    remaining_sessions = Snakepit.list_sessions()
    
    for session <- remaining_sessions do
      Logger.warn("Cleaning up orphaned session: #{session}")
      Snakepit.cleanup_session(session)
    end
    
    {:reply, :ok, state}
  end
end
```

## Benefits

1. **Guaranteed Cleanup**: The `after` block in the runner ensures cleanup always happens
2. **Resource Tracking**: All resources are automatically tracked when created
3. **Consistent Interface**: All demos follow the same pattern
4. **Error Handling**: Failures in one step don't prevent cleanup
5. **Testability**: Each step can be tested independently
6. **Composability**: Steps can be reused across demos

## Implementation Strategy

1. **Phase 1**: Implement the core behavior and runner
2. **Phase 2**: Create helpers for common operations
3. **Phase 3**: Migrate existing demos to use the behavior
4. **Phase 4**: Add advanced features (parallel steps, conditional execution)

## Alternative Approaches

### 1. Process-Based Cleanup

Use a dedicated process that monitors demo execution:

```elixir
defmodule SnakepitShowcase.DemoSupervisor do
  use Supervisor
  
  def start_demo(demo_module) do
    # Start a supervised process for the demo
    DynamicSupervisor.start_child(
      __MODULE__,
      {DemoWorker, demo_module}
    )
  end
end
```

### 2. Macro-Based Resource Tracking

Use macros to wrap resource creation:

```elixir
defmodule SnakepitShowcase.DemoMacros do
  defmacro with_tracked_session(name, do: block) do
    quote do
      session = create_session(unquote(name))
      @tracked_sessions session
      try do
        unquote(block)
      after
        cleanup_session(session)
      end
    end
  end
end
```

### 3. Middleware Pattern

Use a middleware pattern for resource management:

```elixir
defmodule SnakepitShowcase.DemoMiddleware do
  def wrap(demo_fun) do
    fn ->
      before_demo()
      try do
        demo_fun.()
      after
        after_demo()
      end
    end
  end
end
```

## Conclusion

The behavior-based approach provides the best balance of:
- Automatic resource management
- Clear, consistent structure
- Flexibility for different demo types
- Compile-time guarantees through behaviors
- Runtime safety through cleanup tracking

This approach ensures that demos can fail gracefully without leaving the system in an inconsistent state, making the showcase more robust and maintainable.