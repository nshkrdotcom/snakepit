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

  @doc """
  Register a worker process for cleanup tracking.
  Note: This is now a no-op since ProcessRegistry is the single source of truth.
  """
  def register_worker_process(pid) when is_integer(pid) do
    # No-op: ProcessRegistry handles tracking
    :ok
  end

  @doc """
  Unregister a worker process (normal cleanup).
  Note: This is now a no-op since ProcessRegistry handles cleanup.
  """
  def unregister_worker_process(pid) when is_integer(pid) do
    # No-op: ProcessRegistry handles cleanup
    :ok
  end

  @doc """
  Force cleanup all tracked worker processes.
  """
  def force_cleanup_all do
    GenServer.call(__MODULE__, :force_cleanup_all)
  end

  def handle_call(:force_cleanup_all, _from, state) do
    # Query ProcessRegistry for ALL registered PIDs (workers may already be terminated)
    all_pids = Snakepit.Pool.ProcessRegistry.get_all_process_pids()
    killed_count = force_kill_worker_processes(all_pids)
    {:reply, killed_count, state}
  end

  # This is called when the VM is shutting down
  def terminate(reason, _state) do
    Logger.warning("🛑 Application shutting down: #{inspect(reason)}")

    # Query the single source of truth for ALL registered process PIDs (workers may be dead)
    all_pids = Snakepit.Pool.ProcessRegistry.get_all_process_pids()
    Logger.warning("🔥 Force killing #{length(all_pids)} worker processes found in registry")

    killed_count = force_kill_worker_processes(all_pids)

    Logger.warning("✅ Application cleanup completed: #{killed_count} processes killed")
    :ok
  end

  defp force_kill_worker_processes(pids) do
    Enum.reduce(pids, 0, fn pid, acc ->
      try do
        # Kill process group first (negative PID)
        case System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true) do
          {_output, 0} ->
            acc + 1

          {_error, _} ->
            # Fallback to single process kill
            case System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true) do
              {_output, 0} -> acc + 1
              {_error, _} -> acc
            end
        end
      rescue
        # Only rescue specific, expected errors
        e in [ArgumentError] ->
          Logger.error("Failed to kill process with invalid PID #{inspect(pid)}: #{inspect(e)}")
          # Continue, but log the problem
          acc

        # Log other unexpected errors explicitly  
        e ->
          Logger.error(
            "Unexpected exception during worker cleanup for PID #{inspect(pid)}: #{inspect(e)}"
          )

          # Continue cleanup for other processes
          acc
      end
    end)
  end
end
