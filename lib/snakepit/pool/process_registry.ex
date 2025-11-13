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
  alias Snakepit.Logger, as: SLog

  @table_name :snakepit_pool_process_registry
  @cleanup_interval 30_000

  defstruct [
    :table,
    :dets_table,
    :beam_run_id,
    :beam_os_pid
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserves a worker slot before spawning the process.
  This ensures we can track the process even if we crash during spawn.
  """
  def reserve_worker(worker_id) do
    GenServer.call(__MODULE__, {:reserve_worker, worker_id})
  end

  @doc """
  Activates a reserved worker with its actual process information.

  This is a synchronous call that blocks until the worker is registered.
  This ensures the happens-before relationship: worker registration completes
  before the worker is considered ready for work.
  """
  def activate_worker(worker_id, elixir_pid, process_pid, fingerprint) do
    GenServer.call(
      __MODULE__,
      {:activate_worker, worker_id, elixir_pid, process_pid, fingerprint},
      5000
    )
  end

  @doc """
  Registers a worker with its external process information.
  @deprecated Use reserve_worker/1 followed by activate_worker/4 instead
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
  Get the current BEAM run ID.
  """
  def get_beam_run_id() do
    GenServer.call(__MODULE__, :get_beam_run_id)
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

  @doc """
  Returns the number of entries currently stored in the DETS table.
  """
  def dets_table_size do
    GenServer.call(__MODULE__, :dets_table_size)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Generate short 7-character run ID for this BEAM instance
    # This will be embedded in Python CLI commands for reliable tracking
    run_id = Snakepit.RunID.generate()
    # Keep as beam_run_id for backward compatibility
    beam_run_id = run_id

    # CRITICAL: Get the BEAM OS PID for robust stale entry detection
    # This allows us to verify if the BEAM that created an entry is still running
    beam_os_pid = System.pid() |> String.to_integer()

    # Create a proper file path for DETS
    # Include node name to prevent conflicts between multiple BEAM instances
    priv_dir = :code.priv_dir(:snakepit) |> to_string()

    # Sanitize node name for filesystem usage
    node_name = node() |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    dets_file = Path.join([priv_dir, "data", "process_registry_#{node_name}.dets"])

    # Ensure directory exists for DETS file
    dets_dir = Path.dirname(dets_file)
    File.mkdir_p!(dets_dir)

    # Open DETS for persistence with repair option
    # Generate an unguessable table identifier so callers cannot mutate DETS directly.
    dets_table_name =
      :crypto.strong_rand_bytes(8)
      |> Base.encode32(case: :lower)
      |> then(&:"snakepit_process_registry_dets_#{&1}")

    dets_result =
      :dets.open_file(dets_table_name, [
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
          SLog.error("Failed to open DETS file: #{inspect(reason)}. Deleting and recreating...")
          File.rm(dets_file)

          {:ok, table} =
            :dets.open_file(dets_table_name, [
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

    SLog.info(
      "Snakepit Pool Process Registry started with BEAM run ID: #{beam_run_id}, BEAM OS PID: #{beam_os_pid}"
    )

    # Perform startup cleanup of orphaned processes FIRST
    cleanup_orphaned_processes(dets_table, beam_run_id, beam_os_pid)

    # Load current run's processes into ETS
    load_current_run_processes(dets_table, table, beam_run_id)

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok,
     %__MODULE__{
       table: table,
       dets_table: dets_table,
       beam_run_id: beam_run_id,
       beam_os_pid: beam_os_pid
     }}
  end

  @impl true
  def handle_cast({:register, worker_id, elixir_pid, process_pid, fingerprint}, state) do
    worker_info = %{
      elixir_pid: elixir_pid,
      process_pid: process_pid,
      fingerprint: fingerprint,
      registered_at: System.system_time(:second),
      beam_run_id: state.beam_run_id,
      beam_os_pid: state.beam_os_pid,
      pgid: process_pid
    }

    # Atomic write to both ETS and DETS
    :ets.insert(state.table, {worker_id, worker_info})
    :dets.insert(state.dets_table, {worker_id, worker_info})
    # CRITICAL: Force immediate sync to prevent orphans on crash
    :dets.sync(state.dets_table)

    SLog.info(
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
        SLog.info("🚮 Unregistered worker #{worker_id} with external process PID #{process_pid}")

      [] ->
        # Also check DETS in case ETS was cleared
        :dets.delete(state.dets_table, worker_id)
        # Defensive check: Only log at debug level for unknown workers
        # This is expected during certain race conditions and shouldn't be a warning
        SLog.debug(
          "Attempted to unregister unknown worker #{worker_id} - ignoring (worker may have failed to register)"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(
        {:activate_worker, worker_id, elixir_pid, process_pid, fingerprint},
        _from,
        state
      ) do
    worker_info = %{
      status: :active,
      elixir_pid: elixir_pid,
      process_pid: process_pid,
      fingerprint: fingerprint,
      registered_at: System.system_time(:second),
      beam_run_id: state.beam_run_id,
      beam_os_pid: state.beam_os_pid,
      pgid: process_pid
    }

    # Update both ETS and DETS atomically
    :ets.insert(state.table, {worker_id, worker_info})
    :dets.insert(state.dets_table, {worker_id, worker_info})
    # Sync immediately for activation too
    :dets.sync(state.dets_table)

    SLog.debug(
      "🆕 Worker activated: #{worker_id} | PID #{process_pid} | " <>
        "BEAM run #{state.beam_run_id} | Elixir PID: #{inspect(elixir_pid)}"
    )

    # Reply :ok to unblock the caller - worker is now fully registered
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reserve_worker, worker_id}, _from, state) do
    reservation_info = %{
      status: :reserved,
      reserved_at: System.system_time(:second),
      beam_run_id: state.beam_run_id,
      beam_os_pid: state.beam_os_pid
    }

    # CRITICAL: Persist to DETS immediately and sync
    :dets.insert(state.dets_table, {worker_id, reservation_info})
    # Force immediate write to disk
    :dets.sync(state.dets_table)

    SLog.info("Reserved worker slot #{worker_id} for BEAM run #{state.beam_run_id}")
    {:reply, :ok, state}
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
      |> Enum.filter(fn
        {_id, %{status: :active, elixir_pid: pid}} -> Process.alive?(pid)
        # Legacy entries without status
        {_id, %{elixir_pid: pid}} -> Process.alive?(pid)
        _ -> false
      end)
      |> Enum.map(fn {_id, info} -> Map.get(info, :process_pid) end)
      |> Enum.filter(&(&1 != nil))

    {:reply, pids, state}
  end

  @impl true
  def handle_call(:get_all_process_pids, _from, state) do
    pids =
      :ets.tab2list(state.table)
      |> Enum.filter(fn
        {_id, %{status: :active}} -> true
        # Legacy entries
        {_id, %{process_pid: _}} -> true
        _ -> false
      end)
      |> Enum.map(fn {_id, info} -> Map.get(info, :process_pid) end)
      |> Enum.filter(&(&1 != nil))

    {:reply, pids, state}
  end

  @impl true
  def handle_call(:get_beam_run_id, _from, state) do
    {:reply, state.beam_run_id, state}
  end

  @impl true
  def handle_call(:cleanup_dead_workers, _from, state) do
    dead_count = do_cleanup_dead_workers(state.table)
    {:reply, dead_count, state}
  end

  @impl true
  def handle_call(:manual_orphan_cleanup, _from, state) do
    SLog.info("Manual orphan cleanup triggered")
    cleanup_orphaned_processes(state.dets_table, state.beam_run_id, state.beam_os_pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:debug_show_all_entries, _from, state) do
    all_entries = :dets.match_object(state.dets_table, :_)

    entries_info =
      Enum.map(all_entries, fn {worker_id, info} ->
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
  def handle_call(:dets_table_size, _from, state) do
    reply =
      case state.dets_table do
        nil ->
          {:error, :not_initialized}

        table ->
          {:ok, :dets.info(table, :size)}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:cleanup_dead_workers, state) do
    dead_count = do_cleanup_dead_workers(state.table)

    if dead_count > 0 do
      SLog.info("Cleaned up #{dead_count} dead worker entries")
    end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    SLog.debug("ProcessRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    SLog.info("Snakepit Pool Process Registry terminating: #{inspect(reason)}")

    # Log current state before closing
    all_entries = :dets.match_object(state.dets_table, :_)
    SLog.info("ProcessRegistry terminating with #{length(all_entries)} entries in DETS")

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

  defp cleanup_orphaned_processes(dets_table, current_beam_run_id, current_beam_os_pid) do
    SLog.debug(
      "Starting orphan cleanup for BEAM run #{current_beam_run_id}, BEAM OS PID #{current_beam_os_pid}"
    )

    # Get all entries in DETS
    all_entries = :dets.match_object(dets_table, :_)
    SLog.info("Total entries in DETS: #{length(all_entries)}")

    # ROBUST cleanup: Check if the BEAM that created each entry is still running
    # If the BEAM is dead, the entry is stale regardless of run_id or status

    stale_entries =
      all_entries
      |> Enum.filter(fn {_worker_id, info} ->
        cond do
          # Check if this entry has beam_os_pid (new format)
          Map.has_key?(info, :beam_os_pid) ->
            beam_dead = not Snakepit.ProcessKiller.process_alive?(info.beam_os_pid)

            if beam_dead do
              SLog.info("Entry is stale: BEAM OS PID #{info.beam_os_pid} is dead")

              true
            else
              # BEAM still alive - check if it's from current BEAM or different BEAM
              if info.beam_os_pid == current_beam_os_pid do
                # Same BEAM, different run_id shouldn't happen but could indicate restart
                # Keep if from current run, remove if from old run
                info.beam_run_id != current_beam_run_id
              else
                # Different BEAM instance still running - don't kill their processes!
                false
              end
            end

          # Legacy entry without beam_os_pid - use old logic (different run = stale)
          Map.has_key?(info, :beam_run_id) ->
            info.beam_run_id != current_beam_run_id

          # Malformed entry (no beam_run_id at all)
          true ->
            true
        end
      end)

    SLog.info("Found #{length(stale_entries)} stale entries to remove (from previous runs)")

    # 1. Get all ACTIVE processes from PREVIOUS runs (we have their PIDs)
    old_run_orphans =
      :dets.select(dets_table, [
        {{:"$1", :"$2"},
         [
           {:andalso, {:"/=", {:map_get, :beam_run_id, :"$2"}, current_beam_run_id},
            {
              :orelse,
              {:==, {:map_get, :status, :"$2"}, :active},
              # Legacy entries without status field
              {:==, {:map_size, :"$2"}, 6}
            }}
         ], [{{:"$1", :"$2"}}]}
      ])

    SLog.info("Found #{length(old_run_orphans)} active processes from previous BEAM runs")

    # 2. Get abandoned reservations from ANY run
    # During startup, we're more aggressive - any reservation not from current run is abandoned
    # For current run, only consider old reservations (>60s)
    now = System.system_time(:second)

    abandoned_reservations =
      all_entries
      |> Enum.filter(fn {_id, info} ->
        Map.get(info, :status) == :reserved and
          (info.beam_run_id != current_beam_run_id or
             now - Map.get(info, :reserved_at, 0) > 60)
      end)

    SLog.info("Found #{length(abandoned_reservations)} abandoned reservations")

    # Kill active processes with known PIDs using ProcessKiller
    killed_count =
      Enum.reduce(old_run_orphans, 0, fn {worker_id, info}, acc ->
        if Snakepit.ProcessKiller.process_alive?(info.process_pid) do
          SLog.warning(
            "Found orphaned process #{info.process_pid} (worker: #{worker_id}) from previous " <>
              "BEAM run #{info.beam_run_id}. Terminating..."
          )

          # CRITICAL: Verify this is actually a Python grpc_server process with the OLD beam_run_id
          # This prevents killing NEW workers if OS reused the PID
          case Snakepit.ProcessKiller.get_process_command(info.process_pid) do
            {:ok, cmd} ->
              # Must match BOTH grpc_server.py AND the original beam_run_id
              # Support both old format (--snakepit-run-id) and new format (--run-id)
              has_grpc_server = String.contains?(cmd, "grpc_server.py")
              has_old_run_id = String.contains?(cmd, "--snakepit-run-id #{info.beam_run_id}")
              has_new_run_id = String.contains?(cmd, "--run-id #{info.beam_run_id}")

              SLog.warning(
                "🔍 PID REUSE CHECK: PID #{info.process_pid} | Expected run_id: #{info.beam_run_id} | " <>
                  "Current BEAM run_id: #{current_beam_run_id} | Process cmd: #{String.trim(cmd)}"
              )

              if has_grpc_server and (has_old_run_id or has_new_run_id) do
                SLog.info(
                  "Confirmed PID #{info.process_pid} is a grpc_server process with matching run_id"
                )

                # Kill with escalation (SIGTERM -> wait -> SIGKILL)
                case Snakepit.ProcessKiller.kill_with_escalation(info.process_pid) do
                  :ok ->
                    SLog.info("Process #{info.process_pid} successfully terminated")

                  {:error, reason} ->
                    SLog.error("Failed to kill process #{info.process_pid}: #{inspect(reason)}")
                end
              else
                # PID was reused for a different process or different beam_run_id
                if has_grpc_server do
                  SLog.warning(
                    "PID #{info.process_pid} is a grpc_server process but with DIFFERENT beam_run_id. " <>
                      "OS reused PID for new worker! Skipping kill. Command: #{String.trim(cmd)}"
                  )
                else
                  SLog.debug(
                    "PID #{info.process_pid} is not a grpc_server process, skipping: #{String.trim(cmd)}"
                  )
                end
              end

            {:error, _} ->
              SLog.debug("Process #{info.process_pid} not found, already dead")
          end

          acc + 1
        else
          SLog.debug("Orphaned entry #{worker_id} with PID #{info.process_pid} already dead")
          acc
        end
      end)

    # Kill processes from abandoned reservations using run_id-based cleanup
    abandoned_killed =
      abandoned_reservations
      |> Enum.map(fn {worker_id, info} ->
        SLog.debug(
          "Found abandoned reservation #{worker_id} from run #{info.beam_run_id}. " <>
            "Attempting cleanup..."
        )

        # Use ProcessKiller to find and kill processes with this run_id
        {:ok, count} = Snakepit.ProcessKiller.kill_by_run_id(info.beam_run_id)
        SLog.info("Killed #{count} processes for run #{info.beam_run_id}")
        count
      end)
      |> Enum.sum()

    # Combine all entries to remove:
    # - Orphans from old runs (active processes to kill)
    # - Abandoned reservations (never activated)
    # - Stale entries (dead/malformed/old)
    entries_to_remove =
      (old_run_orphans ++ abandoned_reservations ++ stale_entries)
      # Remove duplicates
      |> Enum.uniq_by(fn {worker_id, _} -> worker_id end)

    Enum.each(entries_to_remove, fn {worker_id, _info} ->
      :dets.delete(dets_table, worker_id)
    end)

    # PHASE 3: Scan for rogue Python processes not in DETS
    # This catches processes that were created but never persisted to DETS
    rogue_killed = cleanup_rogue_processes(current_beam_run_id)

    SLog.info(
      "Orphan cleanup complete. Killed #{killed_count} orphaned processes, " <>
        "killed #{abandoned_killed} from abandoned reservations, " <>
        "killed #{rogue_killed} rogue processes, " <>
        "removed #{length(stale_entries)} stale entries, " <>
        "total removed: #{length(entries_to_remove)} entries."
    )
  end

  defp cleanup_rogue_processes(current_beam_run_id) do
    cleanup_config =
      Application.get_env(:snakepit, :rogue_cleanup, enabled: true)
      |> normalize_cleanup_config()

    if cleanup_config[:enabled] == false do
      SLog.info("Skipping rogue process cleanup (disabled via :rogue_cleanup config)")
      0
    else
      python_commands =
        Snakepit.ProcessKiller.find_python_processes()
        |> Enum.reduce([], fn pid, acc ->
          case Snakepit.ProcessKiller.get_process_command(pid) do
            {:ok, cmd} -> [{pid, cmd} | acc]
            _ -> acc
          end
        end)

      owned_processes =
        Enum.filter(python_commands, fn {_pid, cmd} ->
          snakepit_command?(cmd) and has_run_marker?(cmd)
        end)

      SLog.info(
        "Found #{length(owned_processes)} snakepit grpc_server processes with run markers"
      )

      rogue_processes =
        Enum.filter(owned_processes, fn {_pid, cmd} ->
          cleanup_candidate?(cmd, current_beam_run_id)
        end)

      if rogue_processes != [] do
        rogue_pids = Enum.map(rogue_processes, fn {pid, _cmd} -> pid end)

        SLog.warning(
          "Found #{length(rogue_processes)} rogue grpc_server processes not belonging to current run"
        )

        SLog.warning("Rogue PIDs: #{inspect(rogue_pids)}")
      end

      Enum.reduce(rogue_processes, 0, fn {pid, cmd}, acc ->
        SLog.warning("Killing rogue process #{pid}: #{String.trim(cmd)}")

        case Snakepit.ProcessKiller.kill_with_escalation(pid) do
          :ok ->
            acc + 1

          {:error, reason} ->
            SLog.error("Failed to kill rogue process #{pid}: #{inspect(reason)}")
            acc
        end
      end)
    end
  end

  @grpc_scripts ["grpc_server.py", "grpc_server_threaded.py"]
  @run_markers ["--snakepit-run-id", "--run-id"]

  @doc false
  def cleanup_candidate?(command, current_run_id) when is_binary(command) do
    snakepit_command?(command) and has_run_marker?(command) and
      not has_run_id?(command, current_run_id)
  end

  defp snakepit_command?(command) do
    Enum.any?(@grpc_scripts, &String.contains?(command, &1))
  end

  defp has_run_marker?(command) do
    Enum.any?(@run_markers, &String.contains?(command, &1))
  end

  defp has_run_id?(command, run_id) when is_binary(run_id) do
    Enum.any?(@run_markers, fn marker ->
      String.contains?(command, "#{marker} #{run_id}")
    end)
  end

  defp normalize_cleanup_config(%{} = config), do: Map.put_new(config, :enabled, true)

  defp normalize_cleanup_config(config) when is_list(config),
    do: Enum.into(config, %{}) |> normalize_cleanup_config()

  defp normalize_cleanup_config(_), do: %{enabled: true}

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

    SLog.info("Loaded #{length(current_processes)} processes from current BEAM run")
  end

  # Delegate to ProcessKiller for process checking
  defp process_alive?(pid), do: Snakepit.ProcessKiller.process_alive?(pid)

  # Helper function for cleanup that operates on the table
  defp do_cleanup_dead_workers(table) do
    dead_workers =
      :ets.tab2list(table)
      |> Enum.filter(fn {_id, %{elixir_pid: pid}} -> not Process.alive?(pid) end)

    Enum.each(dead_workers, fn {worker_id, %{process_pid: process_pid}} ->
      :ets.delete(table, worker_id)
      # Also delete from DETS - need to pass state or dets_table
      # This will be handled by the unregister_worker call from the worker's terminate
      SLog.info("Cleaned up dead worker #{worker_id} with external process PID #{process_pid}")
    end)

    length(dead_workers)
  end
end
