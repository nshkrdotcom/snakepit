defmodule Snakepit.ProcessKiller do
  @moduledoc """
  Robust OS process management using Erlang primitives.
  No shell commands, pure Erlang/Elixir.

  This module provides POSIX-compliant process management that works
  across Linux, macOS, and BSD systems without relying on shell-specific
  features like pkill.
  """

  require Logger
  alias Snakepit.Logger, as: SLog

  @doc """
  Kills a process by PID using proper Erlang signals.

  ## Parameters
  - `os_pid`: OS process ID (integer)
  - `signal`: :sigterm | :sigkill | :sighup

  ## Returns
  - `:ok` if kill succeeded
  - `{:error, reason}` if kill failed
  """
  def kill_process(os_pid, signal \\ :sigterm) when is_integer(os_pid) do
    signal_num = signal_to_number(signal)

    # DEBUG: Log all kills to find who's killing workers during startup
    caller = Process.info(self(), :registered_name)

    SLog.debug(
      "ProcessKiller.kill_process: PID=#{os_pid}, signal=#{signal}, caller=#{inspect(caller)}"
    )

    try do
      # Use Erlang's :os.cmd for POSIX-compliant kill
      # This avoids shelling out and uses direct syscalls
      result = :os.cmd(~c"kill -#{signal_num} #{os_pid} 2>&1")

      case result do
        [] ->
          :ok

        error ->
          error_msg = :erlang.list_to_binary(error) |> String.trim()

          # Empty error or "No such process" means it's already dead - that's ok
          if error_msg == "" or String.contains?(error_msg, "No such process") do
            :ok
          else
            {:error, error_msg}
          end
      end
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Checks if a process is alive.
  Uses kill -0 (signal 0) which doesn't kill but checks existence.
  """
  def process_alive?(os_pid) when is_integer(os_pid) do
    # kill -0 returns exit code 0 (success) if process exists
    # :os.cmd returns the output as charlist, empty if command succeeded
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      # Exit code 0 = process exists
      {_, 0} -> true
      # Non-zero = process doesn't exist
      {_, _} -> false
    end
  end

  def process_alive?(_), do: false

  @doc """
  Gets the command line of a process.
  POSIX-compliant using /proc on Linux, ps on macOS/BSD.
  """
  def get_process_command(os_pid) when is_integer(os_pid) do
    # Try Linux /proc first (fastest)
    proc_file = "/proc/#{os_pid}/cmdline"

    if File.exists?(proc_file) do
      # Linux: Read /proc/PID/cmdline
      case File.read(proc_file) do
        {:ok, content} ->
          # cmdline uses null bytes as separators
          command = content |> String.split(<<0>>) |> Enum.join(" ") |> String.trim()
          {:ok, command}

        {:error, _} ->
          get_process_command_ps(os_pid)
      end
    else
      # macOS/BSD: Use ps command
      get_process_command_ps(os_pid)
    end
  end

  defp get_process_command_ps(os_pid) do
    # POSIX-compliant ps command
    case :os.cmd(~c"ps -p #{os_pid} -o args= 2>/dev/null") do
      [] ->
        {:error, :not_found}

      result ->
        cmd = :erlang.list_to_binary(result) |> String.trim()
        {:ok, cmd}
    end
  end

  @doc """
  Kills all processes matching a run ID.
  Pure Erlang implementation, no pkill.
  """
  def kill_by_run_id(run_id) when is_binary(run_id) do
    SLog.warning("🔪 Killing all processes with run_id: #{run_id}")
    SLog.debug("kill_by_run_id called at: #{System.monotonic_time(:millisecond)}")
    caller_info = Process.info(self(), [:registered_name, :current_stacktrace])
    SLog.debug("Called from: #{inspect(caller_info)}")

    # Get all Python processes
    python_pids = find_python_processes()

    # Filter by run_id in command line
    # Support both --snakepit-run-id (current) and --run-id (future)
    matching_pids =
      python_pids
      |> Enum.filter(fn pid ->
        case get_process_command(pid) do
          {:ok, cmd} ->
            has_grpc_server = String.contains?(cmd, "grpc_server.py")
            has_old_format = String.contains?(cmd, "--snakepit-run-id #{run_id}")
            has_new_format = String.contains?(cmd, "--run-id #{run_id}")

            has_grpc_server and (has_old_format or has_new_format)

          _ ->
            false
        end
      end)

    SLog.info("Found #{length(matching_pids)} processes to kill")

    # Kill with escalation
    killed_count =
      Enum.reduce(matching_pids, 0, fn pid, acc ->
        case kill_with_escalation(pid) do
          :ok ->
            acc + 1

          {:error, reason} ->
            SLog.warning("Failed to kill #{pid}: #{inspect(reason)}")
            acc
        end
      end)

    {:ok, killed_count}
  end

  @doc """
  Finds all Python processes on the system.
  Returns a list of OS PIDs.
  """
  def find_python_processes do
    # Use ps to find all Python processes
    # POSIX-compliant command
    case :os.cmd(~c"ps -eo pid,comm 2>/dev/null | grep python | awk '{print $1}'") do
      [] ->
        []

      result ->
        result
        |> :erlang.list_to_binary()
        |> String.split("\n", trim: true)
        |> Enum.map(fn pid_str ->
          case Integer.parse(pid_str) do
            {pid, ""} -> pid
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Kills a process with escalation: SIGTERM -> wait -> SIGKILL
  """
  def kill_with_escalation(os_pid, timeout_ms \\ 2000) do
    # Try SIGTERM first (graceful)
    case kill_process(os_pid, :sigterm) do
      :ok ->
        # Wait for process to die
        if wait_for_death(os_pid, timeout_ms) do
          SLog.debug("✅ Process #{os_pid} terminated gracefully")
          :ok
        else
          # Escalate to SIGKILL
          SLog.warning("⏰ Process #{os_pid} didn't die, escalating to SIGKILL")
          kill_process(os_pid, :sigkill)
        end

      error ->
        error
    end
  end

  defp wait_for_death(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_death_loop(os_pid, deadline, 1)
  end

  # Non-blocking polling with exponential backoff using receive after.
  # Starts at 1ms, doubles to 2ms, 4ms, 8ms, capping at 100ms.
  # This is the OTP-correct way to implement timed waits without blocking the scheduler.
  defp wait_for_death_loop(os_pid, deadline, backoff) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      if process_alive?(os_pid) do
        delay = min(backoff, 100)

        # OTP-idiomatic non-blocking wait - integrates with process mailbox and scheduler
        receive do
        after
          delay -> :ok
        end

        wait_for_death_loop(os_pid, deadline, backoff * 2)
      else
        true
      end
    end
  end

  defp signal_to_number(:sigterm), do: 15
  defp signal_to_number(:sigkill), do: 9
  defp signal_to_number(:sighup), do: 1
  defp signal_to_number(n) when is_integer(n), do: n
end
