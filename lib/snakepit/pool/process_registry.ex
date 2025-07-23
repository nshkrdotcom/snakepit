defmodule Snakepit.Pool.ProcessRegistry do
  @moduledoc """
  Registry for tracking external worker processes with OS-level PID management.

  This module maintains a mapping between:
  - Worker IDs
  - Elixir worker PIDs
  - External process PIDs
  - Process fingerprints

  Enables robust orphaned process detection and cleanup.
  """

  use GenServer
  require Logger

  @table_name :snakepit_pool_process_registry
  @dets_table :snakepit_process_registry_dets
  @cleanup_interval 30_000

  defstruct [
    :table,
    :dets_table,
    :beam_run_id
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a worker with its external process information.
  """
  def register_worker(worker_id, elixir_pid, process_pid, fingerprint) do
    GenServer.cast(__MODULE__, {:register, worker_id, elixir_pid, process_pid, fingerprint})
  end

  @doc """
  Unregisters a worker from tracking.
  Returns :ok regardless of whether the worker was registered.
  """
  def unregister_worker(worker_id) do
    GenServer.cast(__MODULE__, {:unregister, worker_id})
  end

  @doc """
  Checks if a worker is currently registered.
  """
  def worker_registered?(worker_id) do
    case :ets.lookup(@table_name, worker_id) do
      [{^worker_id, _}] -> true
      [] -> false
    end
  end

  @doc """
  Gets all active external process PIDs from registered workers.
  """
  def get_active_process_pids() do
    GenServer.call(__MODULE__, :get_active_process_pids)
  end

  @doc """
  Gets all registered external process PIDs, regardless of worker status.

  This is useful during shutdown when workers may have been terminated
  but external processes still need cleanup.
  """
  def get_all_process_pids() do
    GenServer.call(__MODULE__, :get_all_process_pids)
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

    alive_workers =
      Enum.filter(all_workers, fn {_id, %{elixir_pid: pid}} -> Process.alive?(pid) end)

    %{
      total_registered: length(all_workers),
      alive_workers: length(alive_workers),
      dead_workers: length(all_workers) - length(alive_workers),
      active_process_pids: length(get_active_process_pids())
    }
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Generate unique ID for this BEAM run
    beam_run_id = :erlang.unique_integer([:positive, :monotonic])

    # Create a proper file path for DETS
    priv_dir = :code.priv_dir(:snakepit) |> to_string()
    dets_file = Path.join([priv_dir, "data", "process_registry.dets"])

    # Ensure directory exists for DETS file
    dets_dir = Path.dirname(dets_file)
    File.mkdir_p!(dets_dir)

    # Open DETS for persistence
    {:ok, dets_table} =
      :dets.open_file(@dets_table, [
        {:file, to_charlist(dets_file)},
        {:type, :set},
        # Auto-save every 1000ms
        {:auto_save, 1000}
      ])

    # Create ETS table for worker tracking - protected so only GenServer can write
    table =
      :ets.new(@table_name, [
        :set,
        :protected,
        :named_table,
        {:read_concurrency, true}
      ])

    Logger.info("Snakepit Pool Process Registry started with BEAM run ID: #{beam_run_id}")

    # Perform startup cleanup of orphaned processes FIRST
    cleanup_orphaned_processes(dets_table, beam_run_id)

    # Load current run's processes into ETS
    load_current_run_processes(dets_table, table, beam_run_id)

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %__MODULE__{table: table, dets_table: dets_table, beam_run_id: beam_run_id}}
  end

  @impl true
  def handle_cast({:register, worker_id, elixir_pid, process_pid, fingerprint}, state) do
    worker_info = %{
      elixir_pid: elixir_pid,
      process_pid: process_pid,
      fingerprint: fingerprint,
      registered_at: System.system_time(:second),
      beam_run_id: state.beam_run_id,
      # Assuming PID = PGID when using setsid
      pgid: process_pid
    }

    # Atomic write to both ETS and DETS
    :ets.insert(state.table, {worker_id, worker_info})
    :dets.insert(state.dets_table, {worker_id, worker_info})

    Logger.info(
      "✅ Registered worker #{worker_id} with external process PID #{process_pid} " <>
        "for BEAM run #{state.beam_run_id} in ProcessRegistry"
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister, worker_id}, state) do
    case :ets.lookup(state.table, worker_id) do
      [{^worker_id, %{process_pid: process_pid}}] ->
        :ets.delete(state.table, worker_id)
        :dets.delete(state.dets_table, worker_id)
        Logger.info("🚮 Unregistered worker #{worker_id} with external process PID #{process_pid}")

      [] ->
        # Also check DETS in case ETS was cleared
        :dets.delete(state.dets_table, worker_id)
        # Defensive check: Only log at debug level for unknown workers
        # This is expected during certain race conditions and shouldn't be a warning
        Logger.debug(
          "Attempted to unregister unknown worker #{worker_id} - ignoring (worker may have failed to register)"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_worker_info, worker_id}, _from, state) do
    reply =
      case :ets.lookup(state.table, worker_id) do
        [{^worker_id, worker_info}] -> {:ok, worker_info}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:get_active_process_pids, _from, state) do
    pids =
      :ets.tab2list(state.table)
      |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> Process.alive?(pid) end)
      |> Enum.map(fn {_id, %{process_pid: process_pid}} -> process_pid end)
      |> Enum.filter(&(&1 != nil))

    {:reply, pids, state}
  end

  def handle_call(:get_all_process_pids, _from, state) do
    pids =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, %{process_pid: process_pid}} -> process_pid end)
      |> Enum.filter(&(&1 != nil))

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
  def terminate(reason, state) do
    Logger.info("Snakepit Pool Process Registry terminating: #{inspect(reason)}")

    # Ensure DETS is properly closed
    if state.dets_table do
      :dets.close(state.dets_table)
    end

    :ok
  end

  # Private Functions

  defp schedule_cleanup do
    # Clean up dead workers every 30 seconds
    Process.send_after(self(), :cleanup_dead_workers, @cleanup_interval)
  end

  defp cleanup_orphaned_processes(dets_table, current_beam_run_id) do
    Logger.warning("Starting orphan cleanup for BEAM run #{current_beam_run_id}")

    # Get all processes from previous runs
    orphans =
      :dets.select(dets_table, [
        {{:"$1", :"$2"}, [{:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id}],
         [{{:"$1", :"$2"}}]}
      ])

    Enum.each(orphans, fn {worker_id, info} ->
      if process_alive?(info.process_pid) do
        Logger.warning(
          "Found orphaned process #{info.process_pid} from previous " <>
            "BEAM run #{info.beam_run_id}. Terminating..."
        )

        # Try graceful shutdown first
        System.cmd("kill", ["-TERM", to_string(info.process_pid)], stderr_to_stdout: true)
        Process.sleep(2000)

        # Force kill if still alive
        if process_alive?(info.process_pid) do
          System.cmd("kill", ["-KILL", to_string(info.process_pid)], stderr_to_stdout: true)
        end
      end

      # Remove from DETS
      :dets.delete(dets_table, worker_id)
    end)

    Logger.info("Orphan cleanup complete. Killed #{length(orphans)} orphaned processes.")
  end

  defp load_current_run_processes(dets_table, ets_table, beam_run_id) do
    # Load only processes from current BEAM run into ETS
    current_processes =
      :dets.select(dets_table, [
        {{:"$1", :"$2"}, [{:==, {:map_get, :beam_run_id, :"$2"}, beam_run_id}],
         [{{:"$1", :"$2"}}]}
      ])

    Enum.each(current_processes, fn {worker_id, info} ->
      :ets.insert(ets_table, {worker_id, info})
    end)

    Logger.info("Loaded #{length(current_processes)} processes from current BEAM run")
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, to_string(pid))
      _ -> false
    end
  end

  defp process_alive?(_), do: false

  # Helper function for cleanup that operates on the table
  defp do_cleanup_dead_workers(table) do
    dead_workers =
      :ets.tab2list(table)
      |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> not Process.alive?(pid) end)

    Enum.each(dead_workers, fn {worker_id, %{process_pid: process_pid}} ->
      :ets.delete(table, worker_id)
      # Also delete from DETS - need to pass state or dets_table
      # This will be handled by the unregister_worker call from the worker's terminate
      Logger.info("Cleaned up dead worker #{worker_id} with external process PID #{process_pid}")
    end)

    length(dead_workers)
  end
end
