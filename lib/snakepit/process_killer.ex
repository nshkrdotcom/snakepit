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

  @kill_command_candidates ["/bin/kill", "/usr/bin/kill"]
  @ps_command_candidates ["/bin/ps", "/usr/bin/ps"]

  @doc """
  Returns true if the platform supports process group kill semantics.
  """
  def process_group_supported? do
    case :os.type() do
      {:unix, _} ->
        true

      _ ->
        false
    end
  end

  @doc """
  Returns the path to the setsid executable, or {:error, :not_found}.
  """
  def setsid_executable do
    case System.find_executable("setsid") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns the setsid executable path or raises if not available.
  """
  def setsid_executable! do
    case setsid_executable() do
      {:ok, path} -> path
      {:error, _} -> raise "setsid executable not found"
    end
  end

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

    with {:ok, kill_path} <- require_executable("kill", @kill_command_candidates),
         {:ok, output, code} <-
           run_command(kill_path, ["-#{signal_num}", Integer.to_string(os_pid)]) do
      trimmed = String.trim(output || "")

      cond do
        code == 0 ->
          :ok

        String.contains?(trimmed, "No such process") ->
          :ok

        true ->
          {:error, if(trimmed == "", do: {:exit_status, code}, else: trimmed)}
      end
    else
      {:error, reason} ->
        SLog.warning("Failed to execute kill command: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Kills a process group by PGID using proper Erlang signals.

  ## Parameters
  - `pgid`: Process group ID (integer)
  - `signal`: :sigterm | :sigkill | :sighup
  """
  def kill_process_group(pgid, signal \\ :sigterm) when is_integer(pgid) do
    signal_num = signal_to_number(signal)

    with {:ok, kill_path} <- require_executable("kill", @kill_command_candidates),
         {:ok, output, code} <-
           run_command(kill_path, ["-#{signal_num}", "--", "-#{pgid}"]) do
      trimmed = String.trim(output || "")

      cond do
        code == 0 ->
          :ok

        String.contains?(trimmed, "No such process") ->
          :ok

        true ->
          {:error, if(trimmed == "", do: {:exit_status, code}, else: trimmed)}
      end
    else
      {:error, reason} ->
        SLog.warning("Failed to execute kill command: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Checks if a process is alive.
  Uses kill -0 (signal 0) which doesn't kill but checks existence.
  """
  def process_alive?(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:unix, :linux} ->
        process_alive_via_proc(os_pid)

      {:unix, _} ->
        process_alive_via_ps(os_pid)

      _ ->
        false
    end
  end

  def process_alive?(_), do: false

  defp process_alive_via_ps(os_pid) do
    with {:ok, ps_path} <- require_executable("ps", @ps_command_candidates),
         {:ok, output, 0} <-
           run_command(ps_path, ["-p", Integer.to_string(os_pid), "-o", "pid="]) do
      String.trim(output || "") != ""
    else
      _ -> false
    end
  end

  defp process_alive_via_proc(os_pid) do
    stat_path = "/proc/#{os_pid}/stat"

    case File.read(stat_path) do
      {:ok, content} ->
        case parse_proc_state(content) do
          {:ok, state} -> state not in ["Z", "X", "x"]
          :error -> File.exists?(stat_path)
        end

      {:error, :enoent} ->
        false

      {:error, _} ->
        File.exists?(stat_path)
    end
  end

  defp parse_proc_state(content) when is_binary(content) do
    case String.split(content, ") ", parts: 2) do
      [_prefix, rest] ->
        case String.split(rest, " ", parts: 2) do
          [state | _] -> {:ok, state}
          _ -> :error
        end

      _ ->
        :error
    end
  end

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

  @doc """
  Gets the process group ID (PGID) for a process.
  """
  def get_process_group_id(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:unix, :linux} ->
        get_process_group_id_proc(os_pid)

      {:unix, _} ->
        get_process_group_id_ps(os_pid)

      _ ->
        {:error, :not_supported}
    end
  end

  defp get_process_group_id_proc(os_pid) do
    stat_path = "/proc/#{os_pid}/stat"

    case File.read(stat_path) do
      {:ok, content} -> parse_stat_pgid(content)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_stat_pgid(content) do
    case String.split(content, ") ", parts: 2) do
      [_prefix, rest] -> extract_pgid_from_stat(rest)
      _ -> {:error, :parse_error}
    end
  end

  defp extract_pgid_from_stat(rest) do
    case String.split(rest, " ", trim: true) do
      [_state, _ppid, pgrp | _] -> parse_pgid(pgrp)
      _ -> {:error, :parse_error}
    end
  end

  defp parse_pgid(pgrp) do
    case Integer.parse(pgrp) do
      {pgid, ""} -> {:ok, pgid}
      _ -> {:error, :parse_error}
    end
  end

  defp get_process_group_id_ps(os_pid) do
    with {:ok, ps_path} <- require_executable("ps", @ps_command_candidates),
         {:ok, output, 0} <-
           run_command(ps_path, ["-p", Integer.to_string(os_pid), "-o", "pgid="]) do
      case Integer.parse(String.trim(output || "")) do
        {pgid, ""} -> {:ok, pgid}
        _ -> {:error, :not_found}
      end
    else
      {:error, {:executable_not_found, _cmd}} ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp get_process_command_ps(os_pid) do
    with {:ok, ps_path} <- require_executable("ps", @ps_command_candidates),
         {:ok, output, 0} <-
           run_command(ps_path, ["-p", Integer.to_string(os_pid), "-o", "args="]) do
      case String.trim(output || "") do
        "" -> {:error, :not_found}
        cmd -> {:ok, cmd}
      end
    else
      {:error, {:executable_not_found, _cmd}} ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
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

  defp find_python_processes_linux do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.reduce([], &collect_python_pid/2)
        |> Enum.uniq()

      {:error, _} ->
        find_python_processes_posix()
    end
  end

  defp collect_python_pid(entry, acc) do
    case Integer.parse(entry) do
      {pid, ""} ->
        if python_command?(pid), do: [pid | acc], else: acc

      _ ->
        acc
    end
  end

  defp python_command?(pid) do
    comm_path = "/proc/#{pid}/comm"
    cmdline_path = "/proc/#{pid}/cmdline"

    if File.exists?(comm_path) do
      case File.read(comm_path) do
        {:ok, comm} ->
          comm
          |> String.trim()
          |> String.downcase()
          |> String.contains?("python")

        _ ->
          python_cmdline?(cmdline_path)
      end
    else
      python_cmdline?(cmdline_path)
    end
  rescue
    _ -> false
  end

  defp python_cmdline?(path) do
    case File.read(path) do
      {:ok, content} ->
        try do
          content
          |> String.replace(<<0>>, " ")
          |> String.downcase()
          |> String.contains?("python")
        rescue
          ArgumentError -> false
        end

      _ ->
        false
    end
  end

  defp find_python_processes_posix do
    with {:ok, ps_path} <- require_executable("ps", @ps_command_candidates),
         {:ok, output, 0} <- run_command(ps_path, ["-eo", "pid,comm"]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        trimmed = String.trim_leading(line)

        case Regex.split(~r/\s+/, trimmed, parts: 2) do
          [pid_str, command] ->
            with {pid, ""} <- Integer.parse(pid_str),
                 true <- String.contains?(String.downcase(command), "python") do
              [pid | acc]
            else
              _ -> acc
            end

          _ ->
            acc
        end
      end)
      |> Enum.reverse()
    else
      {:error, {:executable_not_found, _cmd}} ->
        SLog.warning("ps command not available; skipping python process discovery")
        []

      _ ->
        []
    end
  end

  @doc """
  Finds all Python processes on the system.
  Returns a list of OS PIDs.
  """
  def find_python_processes do
    case :os.type() do
      {:unix, :linux} -> find_python_processes_linux()
      {:unix, _} -> find_python_processes_posix()
      _ -> []
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

  @doc """
  Kills a process group with escalation: SIGTERM -> wait -> SIGKILL.
  """
  def kill_process_group_with_escalation(pgid, timeout_ms \\ 2000) when is_integer(pgid) do
    case kill_process_group(pgid, :sigterm) do
      :ok ->
        if wait_for_death(pgid, timeout_ms) do
          SLog.debug("✅ Process group #{pgid} terminated gracefully")
          :ok
        else
          SLog.warning("⏰ Process group #{pgid} didn't die, escalating to SIGKILL")
          kill_process_group(pgid, :sigkill)
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

  defp require_executable(cmd, fallback_paths) when is_list(fallback_paths) do
    case System.find_executable(cmd) do
      nil ->
        fallback_paths
        |> Enum.find(&File.exists?/1)
        |> case do
          nil -> {:error, {:executable_not_found, cmd}}
          path -> {:ok, path}
        end

      path ->
        {:ok, path}
    end
  end

  defp run_command(path, args) when is_binary(path) and is_list(args) do
    {output, status} = System.cmd(path, args, stderr_to_stdout: true)
    {:ok, output, status}
  rescue
    error -> {:error, error}
  end
end
