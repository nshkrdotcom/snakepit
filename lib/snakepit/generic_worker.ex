defmodule Snakepit.GenericWorker do
  @moduledoc """
  Generic worker implementation that delegates to configured adapters.
  
  This worker uses the cognitive-ready Snakepit.Adapter behavior to handle
  commands through pluggable adapter implementations.
  """
  
  use GenServer
  require Logger
  
  defstruct [
    :id,
    :adapter_module,
    :adapter_state,
    :stats
  ]
  
  # Client API
  
  @doc """
  Starts a generic worker with the given ID and adapter.
  """
  def start_link(worker_id, adapter_module) do
    GenServer.start_link(__MODULE__, {worker_id, adapter_module})
  end
  
  @doc """
  Execute a command through the adapter.
  """
  def execute(worker_id, command, args, timeout \\ 30_000) do
    case get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:execute, command, args, []}, timeout)
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @doc """
  Execute a streaming command through the adapter (if supported).
  """
  def execute_stream(worker_id, command, args, callback_fn, timeout \\ 300_000) do
    case get_worker_pid(worker_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:execute_stream, command, args, callback_fn, []}, timeout)
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # Server Callbacks
  
  @impl true
  def init({worker_id, adapter_module}) do
    # Validate adapter implements required behavior
    case Snakepit.Adapter.validate_implementation(adapter_module) do
      :ok ->
        # Initialize adapter
        case initialize_adapter(adapter_module) do
          {:ok, adapter_state} ->
            # Register worker with process registry
            :ok = register_worker(worker_id, adapter_module)
            
            state = %__MODULE__{
              id: worker_id,
              adapter_module: adapter_module,
              adapter_state: adapter_state,
              stats: %{
                commands_executed: 0,
                errors: 0,
                total_execution_time: 0
              }
            }
            
            Logger.info("Generic worker #{worker_id} initialized with adapter #{adapter_module}")
            {:ok, state}
            
          {:error, reason} ->
            {:stop, {:adapter_init_failed, reason}}
        end
        
      {:error, missing_callbacks} ->
        {:stop, {:invalid_adapter, missing_callbacks}}
    end
  end
  
  @impl true
  def handle_call({:execute, command, args, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    
    # Add cognitive-ready context
    opts_with_context = opts
    |> Keyword.put(:worker_pid, self())
    |> Keyword.put(:worker_id, state.id)
    
    result = state.adapter_module.execute(command, args, opts_with_context)
    
    # Update statistics
    execution_time = System.monotonic_time(:millisecond) - start_time
    stats = update_stats(state.stats, result, execution_time)
    
    # Report performance metrics to adapter (cognitive-ready feature)
    report_performance_metrics(state.adapter_module, %{
      command: command,
      execution_time_ms: execution_time,
      success: match?({:ok, _}, result)
    }, %{
      worker_id: state.id,
      timestamp: DateTime.utc_now()
    })
    
    {:reply, result, %{state | stats: stats}}
  end
  
  @impl true
  def handle_call({:execute_stream, command, args, callback_fn, opts}, _from, state) do
    # Check if adapter supports streaming
    supports_streaming = if function_exported?(state.adapter_module, :supports_streaming?, 0) do
      state.adapter_module.supports_streaming?()
    else
      false
    end
    
    if supports_streaming do
      # Add cognitive-ready context
      opts_with_context = opts
      |> Keyword.put(:worker_pid, self())
      |> Keyword.put(:worker_id, state.id)
      
      result = state.adapter_module.execute_stream(command, args, callback_fn, opts_with_context)
      
      # Update statistics
      stats = update_stats(state.stats, result, 0)
      
      {:reply, result, %{state | stats: stats}}
    else
      {:reply, {:error, :streaming_not_supported}, state}
    end
  end
  
  @impl true
  def handle_call(:get_stats, _from, state) do
    adapter_metadata = if function_exported?(state.adapter_module, :get_cognitive_metadata, 0) do
      state.adapter_module.get_cognitive_metadata()
    else
      %{}
    end
    
    stats = Map.merge(state.stats, %{
      worker_id: state.id,
      adapter_module: state.adapter_module,
      adapter_metadata: adapter_metadata
    })
    
    {:reply, stats, state}
  end
  
  @impl true
  def terminate(reason, state) do
    Logger.debug("Generic worker #{state.id} terminating: #{inspect(reason)}")
    
    # Clean up adapter if it supports termination
    if function_exported?(state.adapter_module, :terminate, 2) do
      state.adapter_module.terminate(reason, state.adapter_state)
    end
    
    :ok
  end
  
  # Private Functions
  
  defp initialize_adapter(adapter_module) do
    if function_exported?(adapter_module, :init, 1) do
      config = Application.get_env(:snakepit, :adapter_config, [])
      adapter_module.init(config)
    else
      {:ok, nil}
    end
  end
  
  defp register_worker(worker_id, adapter_module) do
    metadata = %{
      worker_module: __MODULE__,
      adapter_module: adapter_module,
      started_at: DateTime.utc_now()
    }
    
    Registry.register(Snakepit.Pool.Registry, worker_id, metadata)
  end
  
  defp get_worker_pid(worker_id) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _metadata}] -> {:ok, pid}
      [] -> {:error, :worker_not_found}
    end
  end
  
  defp update_stats(stats, result, execution_time) do
    stats
    |> Map.update!(:commands_executed, &(&1 + 1))
    |> Map.update!(:total_execution_time, &(&1 + execution_time))
    |> then(fn stats ->
      case result do
        {:ok, _} -> stats
        {:error, _} -> Map.update!(stats, :errors, &(&1 + 1))
      end
    end)
  end
  
  defp report_performance_metrics(adapter_module, metrics, context) do
    if function_exported?(adapter_module, :report_performance_metrics, 2) do
      try do
        adapter_module.report_performance_metrics(metrics, context)
      rescue
        error ->
          Logger.debug("Failed to report performance metrics to adapter: #{inspect(error)}")
      end
    end
  end
end