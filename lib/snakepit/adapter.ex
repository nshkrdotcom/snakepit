defmodule Snakepit.Adapter do
  @moduledoc """
  Behavior for cognitive-ready external process adapters.
  
  Defines the interface that bridge packages must implement to integrate
  with Snakepit Core infrastructure. Includes cognitive-ready hooks for
  future enhancement.
  """

  @doc """
  Execute a command through the external process.
  
  This is the core integration point between Snakepit and bridge implementations.
  
  ## Parameters
  
    * `command` - The command string to execute
    * `args` - Arguments as a map
    * `opts` - Options including worker_pid, session_id, timeout, etc.
  
  ## Returns
  
    * `{:ok, result}` - Successful execution with result
    * `{:error, reason}` - Execution failed with reason
  
  ## Cognitive-Ready Features
  
  Implementations should collect telemetry data for future cognitive enhancement:
  - Execution time tracking
  - Success/failure patterns
  - Resource usage patterns
  - Performance characteristics
  """
  @callback execute(command :: String.t(), args :: map(), opts :: keyword()) :: 
    {:ok, term()} | {:error, term()}

  @doc """
  Execute a streaming command with callback.
  
  Optional callback for adapters that support streaming operations.
  
  ## Parameters
  
    * `command` - The streaming command to execute
    * `args` - Arguments as a map
    * `callback` - Function called for each streaming result
    * `opts` - Options including session context
  
  ## Returns
  
    * `:ok` - Streaming completed successfully
    * `{:error, reason}` - Streaming failed
  """
  @callback execute_stream(
    command :: String.t(), 
    args :: map(), 
    callback :: (term() -> any()), 
    opts :: keyword()
  ) :: :ok | {:error, term()}


  @doc """
  Check if adapter supports streaming operations.
  
  Used by core infrastructure to route streaming requests appropriately.
  """
  @callback supports_streaming?() :: boolean()

  @doc """
  Initialize adapter with configuration.
  
  Called once during pool startup to initialize adapter-specific resources.
  
  ## Parameters
  
    * `config` - Configuration keyword list
  
  ## Returns
  
    * `{:ok, adapter_state}` - Successful initialization with state
    * `{:error, reason}` - Initialization failed
  
  ## Cognitive-Ready Features
  
  Implementations should:
  - Set up telemetry collection infrastructure
  - Initialize performance monitoring
  - Prepare for cognitive enhancement hooks
  """
  @callback init(config :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Clean up adapter resources.
  
  Called during pool shutdown to clean up adapter-specific resources.
  """
  @callback terminate(reason :: term(), adapter_state :: term()) :: term()

  @doc """
  Start a worker process for this adapter.
  
  Called to start individual worker processes that will handle commands.
  
  ## Parameters
  
    * `adapter_state` - State returned from init/1
    * `worker_id` - Unique identifier for this worker
  
  ## Returns
  
    * `{:ok, worker_pid}` - Worker started successfully
    * `{:error, reason}` - Worker startup failed
  """
  @callback start_worker(adapter_state :: term(), worker_id :: term()) :: 
    {:ok, pid()} | {:error, term()}

  @doc """
  Get cognitive-ready metadata about adapter capabilities.
  
  Optional callback that provides metadata for intelligent routing and optimization.
  
  ## Returns
  
  Map containing:
    * `:cognitive_capabilities` - List of supported cognitive features
    * `:performance_characteristics` - Expected performance patterns
    * `:resource_requirements` - Resource usage patterns
    * `:optimization_hints` - Hints for optimization
  """
  @callback get_cognitive_metadata() :: map()

  @doc """
  Report performance metrics to adapter for learning.
  
  Optional callback that allows core infrastructure to provide performance
  feedback to adapters for self-optimization.
  
  ## Parameters
  
    * `metrics` - Performance metrics map
    * `context` - Execution context
  """
  @callback report_performance_metrics(metrics :: map(), context :: map()) :: :ok

  # Optional callbacks
  @optional_callbacks [
    execute_stream: 4,
    supports_streaming?: 0,
    init: 1,
    terminate: 2,
    start_worker: 2,
    get_cognitive_metadata: 0,
    report_performance_metrics: 2
  ]

  @doc """
  Validate that a module properly implements the Snakepit.Adapter behavior.
  
  ## Examples
  
      iex> Snakepit.Adapter.validate_implementation(MyBridge.Adapter)
      :ok
      
      iex> Snakepit.Adapter.validate_implementation(InvalidModule)
      {:error, [:missing_execute_callback]}
  """
  def validate_implementation(nil) do
    {:error, [:no_adapter_configured]}
  end
  
  def validate_implementation(module) when is_atom(module) do
    # Ensure the module is loaded before checking exports
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        required_callbacks = [
          {:execute, 3}
        ]
        
        missing_callbacks = Enum.filter(required_callbacks, fn {function, arity} ->
          not function_exported?(module, function, arity)
        end)
        
        if Enum.empty?(missing_callbacks) do
          :ok
        else
          {:error, missing_callbacks}
        end
        
      {:error, reason} ->
        {:error, {:module_load_failed, reason}}
    end
  end

  @doc """
  Get default cognitive metadata template.
  
  Provides a template that adapter implementations can use as a starting point.
  """
  def default_cognitive_metadata do
    %{
      cognitive_capabilities: [],
      performance_characteristics: %{
        typical_latency_ms: 100,
        throughput_ops_per_sec: 10,
        resource_intensity: :medium
      },
      resource_requirements: %{
        memory_mb: 100,
        cpu_usage: :low,
        network_usage: :medium
      },
      optimization_hints: [
        :supports_batching,
        :benefits_from_caching,
        :session_affinity_beneficial
      ]
    }
  end
end