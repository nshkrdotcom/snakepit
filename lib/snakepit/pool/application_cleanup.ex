defmodule Snakepit.Pool.ApplicationCleanup do
  @moduledoc """
  Provides hard guarantees for worker process cleanup when the application exits.

  This module ensures that NO worker processes survive application shutdown,
  preventing orphaned processes while still allowing normal pool operations.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Trap exits so we can cleanup before the VM dies
    Process.flag(:trap_exit, true)

    # Register for VM shutdown notifications
    :erlang.process_flag(:priority, :high)

    Logger.info("🛡️ Application cleanup handler started")
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
    Logger.info("🔍 Emergency cleanup check (shutdown reason: #{inspect(reason)})")

    beam_run_id = Snakepit.Pool.ProcessRegistry.get_beam_run_id()
    orphaned_pids = find_orphaned_processes(beam_run_id)

    if Enum.empty?(orphaned_pids) do
      Logger.info("✅ No orphaned processes - supervision tree cleaned up correctly")
      emit_telemetry(:cleanup_success, 0)
    else
      Logger.warning("⚠️ Found #{length(orphaned_pids)} orphaned processes!")
      Logger.warning("This indicates the supervision tree failed to clean up properly")
      Logger.warning("Orphaned PIDs: #{inspect(orphaned_pids)}")
      Logger.warning("Investigate why GRPCWorker.terminate or Pool shutdown didn't clean these")

      emit_telemetry(:orphaned_processes_found, length(orphaned_pids))

      # Emergency kill - use SIGKILL directly since supervision already tried SIGTERM
      kill_count = emergency_kill_processes(beam_run_id)

      if kill_count > 0 do
        Logger.warning("🔥 Emergency killed #{kill_count} processes")
        emit_telemetry(:emergency_cleanup, kill_count)
      end
    end

    :ok
  end

  defp find_orphaned_processes(run_id) do
    # Use ProcessKiller to find all Python processes
    python_pids = Snakepit.ProcessKiller.find_python_processes()

    # Filter for grpc_server processes with our run_id
    # Support both old format (--snakepit-run-id) and new format (--run-id)
    python_pids
    |> Enum.filter(fn pid ->
      case Snakepit.ProcessKiller.get_process_command(pid) do
        {:ok, cmd} ->
          has_grpc_server = String.contains?(cmd, "grpc_server.py")
          has_old_format = String.contains?(cmd, "--snakepit-run-id #{run_id}")
          has_new_format = String.contains?(cmd, "--run-id #{run_id}")

          has_grpc_server and (has_old_format or has_new_format)

        _ ->
          false
      end
    end)
  end

  defp emergency_kill_processes(run_id) do
    # Use ProcessKiller with run_id-based cleanup
    case Snakepit.ProcessKiller.kill_by_run_id(run_id) do
      {:ok, killed_count} ->
        killed_count

      {:error, reason} ->
        Logger.error("Emergency cleanup failed: #{inspect(reason)}")
        0
    end
  end

  defp emit_telemetry(event, count) do
    :telemetry.execute(
      [:snakepit, :application_cleanup, event],
      %{count: count},
      %{
        beam_run_id: Snakepit.Pool.ProcessRegistry.get_beam_run_id(),
        timestamp: System.system_time(:second)
      }
    )
  end
end
