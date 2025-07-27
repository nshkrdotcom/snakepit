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
        "🔥 ApplicationCleanup found #{length(all_pids)} surviving processes. Starting graceful termination..."
      )

      # First try SIGTERM for graceful shutdown
      sigterm_count = send_signal_to_processes(all_pids, "TERM")
      Logger.info("Sent SIGTERM to #{sigterm_count} processes")

      # Immediately check which processes are still alive
      # In production, you might want to add a small delay here for graceful shutdown
      still_alive = Enum.filter(all_pids, &process_still_alive?/1)

      if Enum.any?(still_alive) do
        Logger.warning(
          "⚠️  #{length(still_alive)} processes survived SIGTERM. Forcefully terminating with SIGKILL."
        )

        sigkill_count = send_signal_to_processes(still_alive, "KILL")
        Logger.warning("✅ SIGKILL sent to #{sigkill_count} surviving processes")
      else
        Logger.info("✅ All processes terminated gracefully with SIGTERM")
      end
    else
      Logger.info(
        "✅ ApplicationCleanup confirms all external processes were shut down correctly."
      )
    end

    # Final fallback: kill any Python grpc_server processes from THIS beam run that might have been missed
    # This handles cases where setsid PIDs don't match actual process PIDs
    # Using the beam_run_id makes this much more targeted and safe
    beam_run_id = Snakepit.Pool.ProcessRegistry.get_beam_run_id()

    script_pattern = get_script_pattern()
    case System.cmd("pkill", ["-9", "-f", "#{script_pattern}.*--snakepit-run-id #{beam_run_id}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info(
          "🧹 Final cleanup: killed any remaining #{script_pattern} processes from run #{beam_run_id}"
        )

      {_output, 1} ->
        # Exit code 1 means no processes found, which is fine
        :ok

      {output, code} ->
        Logger.warning("pkill returned unexpected code #{code}: #{output}")
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
      # First check if process exists
      case System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true) do
        {_output, 0} ->
          # Process exists, try to kill the process group first
          case System.cmd("kill", ["-#{signal}", "-#{pid}"], stderr_to_stdout: true) do
            {_output, 0} ->
              Logger.debug("Successfully sent #{signal} to process group #{pid}")
              :ok

            {error, _} ->
              Logger.debug(
                "Failed to send #{signal} to process group #{pid}: #{error}, trying individual process"
              )

              # Fallback to killing just the individual process
              case System.cmd("kill", ["-#{signal}", "#{pid}"], stderr_to_stdout: true) do
                {_output, 0} ->
                  Logger.debug("Successfully sent #{signal} to individual process #{pid}")
                  :ok

                {error, _} ->
                  Logger.debug("Failed to send #{signal} to process #{pid}: #{error}")
                  :error
              end
          end

        {_output, _} ->
          # Process doesn't exist
          Logger.debug("Process #{pid} doesn't exist, skipping")
          :error
      end
    rescue
      _ -> :error
    end
  end

  # Check if a process is still alive
  defp process_still_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _} -> false
    end
  end

  defp process_still_alive?(_), do: false

  # Keep the old function for manual cleanup calls
  defp force_kill_worker_processes(pids) do
    Enum.reduce(pids, 0, fn pid, acc ->
      try do
        # Kill process group first (negative PID)
        # This is the proper way to kill all processes in a process group
        case System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.debug("Successfully killed process group #{pid}")
            acc + 1

          {error, exit_code} ->
            Logger.debug(
              "Failed to kill process group #{pid} (exit code: #{exit_code}): #{error}"
            )

            # Fallback to single process kill
            case System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true) do
              {_output, 0} ->
                Logger.debug("Successfully killed individual process #{pid}")
                acc + 1

              {error, exit_code} ->
                Logger.debug("Failed to kill process #{pid} (exit code: #{exit_code}): #{error}")
                acc
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
  
  # Get the script pattern from adapter config or use default
  defp get_script_pattern do
    case Application.get_env(:snakepit, :adapter_config) do
      %{script_pattern: pattern} when is_binary(pattern) ->
        pattern
      _ ->
        # Default to the original pattern for backward compatibility
        "grpc_server.py"
    end
  end
end
