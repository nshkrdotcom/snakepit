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
    Logger.warning("🛑 Application cleanup final check initiated by shutdown: #{inspect(reason)}")

    # The Pool and Workers have already attempted a graceful shutdown.
    # Our job is to be the final, brutal guarantee.
    all_pids = Snakepit.Pool.ProcessRegistry.get_all_process_pids()

    if Enum.any?(all_pids) do
      Logger.warning(
        "🔥 ApplicationCleanup found #{length(all_pids)} surviving processes. Forcefully terminating with SIGKILL."
      )
      # No more grace. Just kill everything that's left.
      sigkill_count = send_signal_to_processes(all_pids, "KILL")
      Logger.warning("✅ SIGKILL sent to #{sigkill_count} surviving processes")
    else
      Logger.info("✅ ApplicationCleanup confirms all external processes were shut down correctly.")
    end

    :ok
  end

  # Send a signal to multiple processes and count successes
  defp send_signal_to_processes(pids, signal) do
    Enum.reduce(pids, 0, fn pid, acc ->
      case send_signal_to_process(pid, signal) do
        :ok -> acc + 1
        :error -> acc
      end
    end)
  end

  # Send a signal to a single process
  defp send_signal_to_process(pid, signal) when is_integer(pid) do
    try do
      case System.cmd("kill", ["-#{signal}", "#{pid}"], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {_error, _} -> :error
      end
    rescue
      _ -> :error
    end
  end

  # Check which PIDs are still alive
  defp get_alive_pids(pids) do
    Enum.filter(pids, fn pid ->
      # "kill -0" is a standard way to check if a process exists without sending a signal
      case System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true) do
        # Process exists
        {_output, 0} -> true
        # Process doesn't exist
        {_error, _} -> false
      end
    end)
  end

  # Keep the old function for manual cleanup calls
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
