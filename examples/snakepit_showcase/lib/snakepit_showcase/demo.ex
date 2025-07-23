defmodule SnakepitShowcase.Demo do
  @moduledoc """
  Behaviour for implementing Snakepit demonstrations with automatic cleanup.
  
  This module provides a consistent interface for demos and ensures that all
  resources (sessions, processes, files, etc.) are properly cleaned up after
  execution, even if the demo fails.
  
  ## Example
  
      defmodule MyDemo do
        use SnakepitShowcase.Demo
        
        @impl true
        def description, do: "My awesome demo"
        
        @impl true
        def steps do
          [
            {:setup, "Initialize the demo"},
            {:execute, "Run the main logic"},
            {:verify, "Verify results"}
          ]
        end
        
        @impl true
        def run_step(:setup, context) do
          session_id = create_tracked_session(context)
          {:ok, %{session_id: session_id}}
        end
        
        # ... implement other steps
      end
  """
  
  @type step :: {atom(), String.t()}
  @type context :: map()
  @type step_result :: {:ok, any()} | {:error, any()}
  
  @doc "Returns a description of what this demo demonstrates"
  @callback description() :: String.t()
  
  @doc "Returns a list of steps that will be executed in order"
  @callback steps() :: [step()]
  
  @doc "Executes a single step of the demo"
  @callback run_step(step_name :: atom(), context :: context()) :: step_result()
  
  @doc "Optional callback to perform custom cleanup"
  @callback cleanup(context :: context()) :: :ok
  
  @optional_callbacks [cleanup: 1]
  
  defmacro __using__(_opts) do
    quote do
      @behaviour SnakepitShowcase.Demo
      
      # Import helper functions
      import SnakepitShowcase.Demo.Helpers
      
      # Default run implementation that delegates to the runner
      def run(opts \\ []) do
        SnakepitShowcase.Demo.Runner.execute(__MODULE__, opts)
      end
      
      # Default cleanup implementation (can be overridden)
      def cleanup(_context), do: :ok
      
      defoverridable [cleanup: 1]
    end
  end
end