defmodule Snakepit.Pool.ProcessRegistry do
  @moduledoc """
  Registry for tracking Python worker processes with OS-level PID management.
  
  This module maintains a mapping between:
  - Worker IDs
  - Elixir worker PIDs
  - Python process PIDs
  - Process fingerprints
  
  Enables robust orphaned process detection and cleanup.
  """
  
  use GenServer
  require Logger
  
  @table_name :snakepit_pool_process_registry
  
  defstruct [
    :table
  ]
  
  # Client API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Registers a worker with its Python process information.
  """
  def register_worker(worker_id, elixir_pid, python_pid, fingerprint) do
    GenServer.cast(__MODULE__, {:register, worker_id, elixir_pid, python_pid, fingerprint})
  end
  
  @doc """
  Unregisters a worker from tracking.
  """
  def unregister_worker(worker_id) do
    GenServer.cast(__MODULE__, {:unregister, worker_id})
  end
  
  @doc """
  Gets all active Python process PIDs from registered workers.
  """
  def get_active_python_pids() do
    GenServer.call(__MODULE__, :get_active_python_pids)
  end
  
  @doc """
  Gets all registered worker information.
  """
  def list_all_workers() do
    :ets.tab2list(@table_name)
  end
  
  @doc """
  Gets information for a specific worker.
  """
  def get_worker_info(worker_id) do
    GenServer.call(__MODULE__, {:get_worker_info, worker_id})
  end
  
  @doc """
  Gets workers with specific fingerprints.
  """
  def get_workers_by_fingerprint(fingerprint) do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_id, %{fingerprint: fp}} -> fp == fingerprint end)
  end
  
  @doc """
  Validates that all registered workers are still alive.
  Returns a list of dead workers that should be cleaned up.
  """
  def validate_workers() do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> not Process.alive?(pid) end)
    |> Enum.map(fn {worker_id, worker_info} -> {worker_id, worker_info} end)
  end
  
  @doc """
  Cleans up dead worker entries from the registry.
  """
  def cleanup_dead_workers() do
    GenServer.call(__MODULE__, :cleanup_dead_workers)
  end
  
  @doc """
  Gets registry statistics.
  """
  def get_stats() do
    all_workers = :ets.tab2list(@table_name)
    alive_workers = Enum.filter(all_workers, fn {_id, %{elixir_pid: pid}} -> Process.alive?(pid) end)
    
    %{
      total_registered: length(all_workers),
      alive_workers: length(alive_workers),
      dead_workers: length(all_workers) - length(alive_workers),
      active_python_pids: length(get_active_python_pids())
    }
  end
  
  # Server Callbacks
  
  @impl true
  def init(_opts) do
    # Create ETS table for worker tracking - protected so only GenServer can write
    table = :ets.new(@table_name, [
      :set,
      :protected,
      :named_table,
      {:read_concurrency, true}
    ])
    
    Logger.info("Snakepit Pool Process Registry started with table #{@table_name}")
    
    # Schedule periodic cleanup
    schedule_cleanup()
    
    {:ok, %__MODULE__{table: table}}
  end
  
  @impl true
  def handle_cast({:register, worker_id, elixir_pid, python_pid, fingerprint}, state) do
    worker_info = %{
      elixir_pid: elixir_pid,
      python_pid: python_pid,
      fingerprint: fingerprint,
      registered_at: System.system_time(:second)
    }
    
    :ets.insert(state.table, {worker_id, worker_info})
    Logger.debug("Registered worker #{worker_id} with Python PID #{python_pid}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister, worker_id}, state) do
    case :ets.lookup(state.table, worker_id) do
      [{^worker_id, %{python_pid: python_pid}}] ->
        :ets.delete(state.table, worker_id)
        Logger.debug("Unregistered worker #{worker_id} with Python PID #{python_pid}")
      [] ->
        Logger.warning("Attempted to unregister unknown worker #{worker_id}")
    end
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_worker_info, worker_id}, _from, state) do
    reply = case :ets.lookup(state.table, worker_id) do
      [{^worker_id, worker_info}] -> {:ok, worker_info}
      [] -> {:error, :not_found}
    end
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:get_active_python_pids, _from, state) do
    pids = :ets.tab2list(state.table)
           |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> Process.alive?(pid) end)
           |> Enum.map(fn {_id, %{python_pid: python_pid}} -> python_pid end)
           |> Enum.filter(& &1 != nil)
    {:reply, pids, state}
  end

  @impl true
  def handle_call(:cleanup_dead_workers, _from, state) do
    dead_count = do_cleanup_dead_workers(state.table)
    {:reply, dead_count, state}
  end

  @impl true
  def handle_info(:cleanup_dead_workers, state) do
    dead_count = do_cleanup_dead_workers(state.table)
    
    if dead_count > 0 do
      Logger.info("Cleaned up #{dead_count} dead worker entries")
    end
    
    # Schedule next cleanup
    schedule_cleanup()
    
    {:noreply, state}
  end
  
  def handle_info(msg, state) do
    Logger.debug("ProcessRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  @impl true
  def terminate(reason, _state) do
    Logger.info("Snakepit Pool Process Registry terminating: #{inspect(reason)}")
    :ok
  end
  
  # Private Functions
  
  defp schedule_cleanup do
    # Clean up dead workers every 30 seconds
    Process.send_after(self(), :cleanup_dead_workers, 30_000)
  end

  # Helper function for cleanup that operates on the table
  defp do_cleanup_dead_workers(table) do
    dead_workers = :ets.tab2list(table)
                   |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> not Process.alive?(pid) end)
    
    Enum.each(dead_workers, fn {worker_id, %{python_pid: python_pid}} ->
      :ets.delete(table, worker_id)
      Logger.info("Cleaned up dead worker #{worker_id} with Python PID #{python_pid}")
    end)
    
    length(dead_workers)
  end
end