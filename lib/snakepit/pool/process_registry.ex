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

  @doc """
  Manually trigger orphan cleanup. Useful for testing and debugging.
  """
  def manual_orphan_cleanup() do
    GenServer.call(__MODULE__, :manual_orphan_cleanup)
  end

  @doc """
  Debug function to show all DETS entries with their BEAM run IDs.
  """
  def debug_show_all_entries() do
    GenServer.call(__MODULE__, :debug_show_all_entries)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Generate unique ID for this BEAM run using timestamp + random component
    # This ensures uniqueness even across BEAM restarts
    timestamp = System.system_time(:microsecond)
    random_component = :rand.uniform(999_999)
    beam_run_id = "#{timestamp}_#{random_component}"

    # Create a proper file path for DETS
    priv_dir = :code.priv_dir(:snakepit) |> to_string()
    dets_file = Path.join([priv_dir, "data", "process_registry.dets"])

    # Ensure directory exists for DETS file
    dets_dir = Path.dirname(dets_file)
    File.mkdir_p!(dets_dir)

    # Open DETS for persistence with repair option
    dets_result =
      :dets.open_file(@dets_table, [
        {:file, to_charlist(dets_file)},
        {:type, :set},
        # Auto-save every 1000ms
        {:auto_save, 1000},
        # Automatically repair corrupted files
        {:repair, true}
      ])

    dets_table =
      case dets_result do
        {:ok, table} ->
          table

        {:error, reason} ->
          Logger.error("Failed to open DETS file: #{inspect(reason)}. Deleting and recreating...")
          File.rm(dets_file)
          {:ok, table} =
            :dets.open_file(@dets_table, [
              {:file, to_charlist(dets_file)},
              {:type, :set},
              {:auto_save, 1000}
            ])

          table
      end

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
    # Force sync to ensure data is written to disk
    :dets.sync(state.dets_table)

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
  def handle_call(:manual_orphan_cleanup, _from, state) do
    Logger.info("Manual orphan cleanup triggered")
    cleanup_orphaned_processes(state.dets_table, state.beam_run_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:debug_show_all_entries, _from, state) do
    all_entries = :dets.match_object(state.dets_table, :_)
    entries_info = Enum.map(all_entries, fn {worker_id, info} ->
      %{
        worker_id: worker_id,
        process_pid: info.process_pid,
        beam_run_id: info.beam_run_id,
        is_current_run: info.beam_run_id == state.beam_run_id,
        process_alive: process_alive?(info.process_pid)
      }
    end)
    {:reply, {entries_info, state.beam_run_id}, state}
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
    
    # Log current state before closing
    all_entries = :dets.match_object(state.dets_table, :_)
    Logger.info("ProcessRegistry terminating with #{length(all_entries)} entries in DETS")

    # Ensure DETS is properly synced and closed
    if state.dets_table do
      :dets.sync(state.dets_table)
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

    # First, log all entries in DETS for debugging
    all_entries = :dets.match_object(dets_table, :_)
    Logger.info("Total entries in DETS: #{length(all_entries)}")

    # Get all processes from previous runs
    orphans =
      :dets.select(dets_table, [
        {{:"$1", :"$2"}, [{:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id}],
         [{{:"$1", :"$2"}}]}
      ])

    Logger.info("Found #{length(orphans)} orphaned entries from previous BEAM runs")

    killed_count =
      Enum.reduce(orphans, 0, fn {worker_id, info}, acc ->
        if process_alive?(info.process_pid) do
          Logger.warning(
            "Found orphaned process #{info.process_pid} (worker: #{worker_id}) from previous " <>
              "BEAM run #{info.beam_run_id}. Terminating..."
          )

          # Try graceful shutdown first with the process group
          pid_str = to_string(info.process_pid)
          
          # First try SIGTERM to the process group (negative PID)
          case System.cmd("kill", ["-TERM", "-#{pid_str}"], stderr_to_stdout: true) do
            {_output, 0} ->
              Logger.info("Sent SIGTERM to process group #{pid_str}")
            {output, _} ->
              Logger.warning("Failed to kill process group, trying individual process: #{output}")
              # Fallback to killing just the process
              System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true)
          end
          
          # Immediately force kill - no waiting
          if process_alive?(info.process_pid) do
            Logger.warning("Process #{info.process_pid} still alive after SIGTERM, force killing...")
            
            # Try SIGKILL to process group first
            case System.cmd("kill", ["-KILL", "-#{pid_str}"], stderr_to_stdout: true) do
              {_output, 0} ->
                Logger.info("Sent SIGKILL to process group #{pid_str}")
              {output, _} ->
                Logger.warning("Failed to force kill process group, trying individual process: #{output}")
                # Fallback to killing just the process
                System.cmd("kill", ["-KILL", pid_str], stderr_to_stdout: true)
            end
            
            # Also try pkill as a last resort
            if process_alive?(info.process_pid) do
              Logger.error("Process #{info.process_pid} STILL alive after SIGKILL, trying more aggressive methods...")
              
              # Try to kill by session ID
              case System.cmd("pkill", ["-KILL", "-s", pid_str], stderr_to_stdout: true) do
                {output, 0} -> Logger.info("Killed processes in session #{pid_str}")
                {output, _} -> Logger.warning("Failed to kill by session: #{output}")
              end
              
              # Try to kill all python processes started by this worker
              case System.cmd("pkill", ["-KILL", "-f", "grpc_server.py.*--port"], stderr_to_stdout: true) do
                {output, 0} -> Logger.info("Killed matching Python processes")
                {output, _} -> Logger.warning("Failed to kill Python processes: #{output}")
              end
              
              # Final check - if STILL alive, it might be a zombie
              if process_alive?(info.process_pid) do
                Logger.error("Process #{info.process_pid} appears to be a zombie or unkillable!")
              end
            end
          else
            Logger.info("Process #{info.process_pid} successfully terminated")
          end

          acc + 1
        else
          Logger.debug("Orphaned entry #{worker_id} with PID #{info.process_pid} already dead")
          acc
        end
      end)

    # Remove all orphaned entries from DETS
    Enum.each(orphans, fn {worker_id, _info} ->
      :dets.delete(dets_table, worker_id)
    end)

    Logger.info("Orphan cleanup complete. Killed #{killed_count} processes, removed #{length(orphans)} entries.")
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
    # First try kill -0 which is more reliable
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.debug("Process #{pid} is alive (kill -0 succeeded)")
        true
        
      {_output, _} ->
        # Double-check with ps to avoid false negatives
        case System.cmd("ps", ["-p", to_string(pid), "-o", "pid,stat,cmd"], stderr_to_stdout: true) do
          {output, 0} ->
            lines = String.split(output, "\n")
            pid_str = to_string(pid)
            
            # Look for the PID in the output, checking for zombie status
            alive = Enum.any?(lines, fn line ->
              if String.contains?(line, pid_str) && !String.contains?(line, "PID") do
                # Check if it's a zombie (Z in STAT column)
                if String.contains?(line, "<defunct>") || String.contains?(line, " Z ") do
                  Logger.debug("Process #{pid} is a zombie")
                  false
                else
                  true
                end
              else
                false
              end
            end)
            
            if alive do
              Logger.debug("Process #{pid} is alive (found in ps)")
            else
              Logger.debug("Process #{pid} not found or is zombie")
            end
            
            alive
            
          {output, exit_code} ->
            Logger.debug("ps command failed with exit code #{exit_code}: #{output}")
            false
        end
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
