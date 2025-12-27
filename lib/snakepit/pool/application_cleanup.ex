defmodule Snakepit.Pool.ApplicationCleanup do
  @moduledoc """
  Provides hard guarantees for worker process cleanup when the application exits.

  This module ensures that NO worker processes survive application shutdown,
  preventing orphaned processes while still allowing normal pool operations.
  """

  use GenServer
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller
  @log_category :shutdown

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Trap exits so we can cleanup before the VM dies
    Process.flag(:trap_exit, true)

    # Register for VM shutdown notifications
    :erlang.process_flag(:priority, :high)

    SLog.info(@log_category, "🛡️ Application cleanup handler started")
    {:ok, %{}}
  end

  # Note: Worker process tracking is handled entirely by ProcessRegistry.
  # ApplicationCleanup queries ProcessRegistry during shutdown for process cleanup.

  # This is called when the VM is shutting down
  #
  # IMPORTANT: This is an EMERGENCY handler. It should rarely do actual work.
  # The supervision tree (GRPCWorker.terminate + Worker.Starter + Pool) should
  # clean up processes during normal shutdown.
  #
  # If this handler finds orphans, it indicates a bug in the supervision tree.
  def terminate(reason, _state) do
    SLog.info(@log_category, "🔍 Emergency cleanup check (shutdown reason: #{inspect(reason)})")

    SLog.debug(
      @log_category,
      "ApplicationCleanup.terminate/2 called at: #{System.monotonic_time(:millisecond)}"
    )

    SLog.debug(@log_category, "ApplicationCleanup process info: #{inspect(Process.info(self()))}")

    beam_run_id = ProcessRegistry.get_beam_run_id()
    orphaned_pids = find_orphaned_processes(beam_run_id)

    if Enum.empty?(orphaned_pids) do
      SLog.info(@log_category, "✅ No orphaned processes - supervision tree cleaned up correctly")
      emit_telemetry(:cleanup_success, 0)
    else
      # These are normal during test shutdown - workers that were still starting
      SLog.debug(
        @log_category,
        "Cleanup: Found #{length(orphaned_pids)} processes still starting during shutdown"
      )

      SLog.debug(@log_category, "Cleanup: Orphaned PIDs: #{inspect(orphaned_pids)}")

      emit_telemetry(:orphaned_processes_found, length(orphaned_pids))

      # Emergency kill - use SIGKILL directly since supervision already tried SIGTERM
      kill_count = emergency_kill_processes(beam_run_id)

      if kill_count > 0 do
        SLog.debug(@log_category, "Cleanup: Killed #{kill_count} orphaned processes")
        emit_telemetry(:emergency_cleanup, kill_count)
      end
    end

    :ok
  end

  defp find_orphaned_processes(run_id) do
    # CRITICAL: Get all registered workers from ProcessRegistry
    # A process is only "orphaned" if its Python process is alive BUT
    # its Elixir GenServer is dead (supervision tree failed to clean it up)
    registered_workers = ProcessRegistry.list_all_workers()

    # Find Python processes for this run_id
    python_pids = ProcessKiller.find_python_processes()

    grpc_pids_for_run = filter_grpc_pids_by_run_id(python_pids, run_id)

    # Filter out processes whose Elixir GenServer is still alive
    # Those are NOT orphans - the supervision tree will clean them up
    Enum.filter(grpc_pids_for_run, fn os_pid ->
      orphaned_process?(os_pid, registered_workers)
    end)
  end

  defp filter_grpc_pids_by_run_id(python_pids, run_id) do
    Enum.filter(python_pids, fn pid ->
      matches_grpc_run_id?(pid, run_id)
    end)
  end

  defp matches_grpc_run_id?(pid, run_id) do
    case ProcessKiller.get_process_command(pid) do
      {:ok, cmd} ->
        has_grpc_server = String.contains?(cmd, "grpc_server.py")
        has_old_format = String.contains?(cmd, "--snakepit-run-id #{run_id}")
        has_new_format = String.contains?(cmd, "--run-id #{run_id}")

        has_grpc_server and (has_old_format or has_new_format)

      _ ->
        false
    end
  end

  defp orphaned_process?(os_pid, registered_workers) do
    worker_entry =
      Enum.find(registered_workers, fn {_worker_id, info} ->
        Map.get(info, :process_pid) == os_pid
      end)

    case worker_entry do
      {_worker_id, %{elixir_pid: elixir_pid}} ->
        check_if_orphan(os_pid, elixir_pid)

      nil ->
        # Not in registry at all - this IS an orphan
        SLog.warning(@log_category, "PID #{os_pid} not in ProcessRegistry - true orphan")
        true
    end
  end

  defp check_if_orphan(os_pid, elixir_pid) do
    # If the Elixir GenServer is still alive, this is NOT an orphan
    # The supervision tree will clean it up - don't interfere!
    is_orphan = not Process.alive?(elixir_pid)

    if not is_orphan do
      SLog.debug(
        @log_category,
        "Skipping PID #{os_pid} - Elixir GenServer #{inspect(elixir_pid)} still alive, " <>
          "supervision tree will handle cleanup"
      )
    end

    is_orphan
  end

  defp emergency_kill_processes(run_id) do
    # Use ProcessKiller with run_id-based cleanup
    {:ok, killed_count} = ProcessKiller.kill_by_run_id(run_id)
    killed_count
  end

  defp emit_telemetry(event, count) do
    :telemetry.execute(
      [:snakepit, :application_cleanup, event],
      %{count: count},
      %{
        beam_run_id: ProcessRegistry.get_beam_run_id(),
        timestamp: System.system_time(:second)
      }
    )
  end
end
