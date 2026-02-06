defmodule Snakepit.RuntimeCleanup do
  @moduledoc """
  Deterministic shutdown cleanup for external worker processes.

  This module performs a bounded cleanup pass:
  - SIGTERM all known worker processes
  - Wait until they exit or timeout
  - Escalate to SIGKILL for survivors
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Defaults
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.ProcessKiller

  @telemetry_start [:snakepit, :cleanup, :start]
  @telemetry_success [:snakepit, :cleanup, :success]
  @telemetry_timeout [:snakepit, :cleanup, :timeout]
  @log_category :shutdown

  def cleanup_current_run(opts \\ []) do
    run_id = ProcessRegistry.get_beam_run_id()
    entries = ProcessRegistry.current_run_entries()
    run(entries, Keyword.put_new(opts, :run_id, run_id))
  end

  def run(entries, opts \\ []) when is_list(entries) do
    timeout_ms = Keyword.get(opts, :timeout_ms, cleanup_on_stop_timeout_ms())
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, cleanup_poll_interval_ms())
    process_group_kill? = Keyword.get(opts, :process_group_kill, process_group_kill_enabled?())
    run_id = Keyword.get(opts, :run_id)

    targets =
      entries
      |> Enum.map(&to_target/1)
      |> Enum.filter(fn target -> is_integer(target.process_pid) end)

    if targets == [] do
      :ok
    else
      emit_telemetry(@telemetry_start, length(targets), run_id)
      kill_targets(targets, :sigterm, process_group_kill?)

      remaining = wait_for_targets(targets, poll_interval_ms, timeout_ms)

      if remaining == [] do
        emit_telemetry(@telemetry_success, length(targets), run_id)
        :ok
      else
        SLog.warning(
          @log_category,
          "Cleanup timeout after #{timeout_ms}ms; escalating to SIGKILL for #{length(remaining)} processes"
        )

        kill_targets(remaining, :sigkill, process_group_kill?)
        still_alive = wait_for_targets(remaining, poll_interval_ms, poll_interval_ms)
        log_incomplete_cleanup(still_alive)
        emit_telemetry(@telemetry_timeout, length(remaining), run_id)
        {:timeout, still_alive}
      end
    end
  end

  defp to_target({worker_id, info}) when is_map(info) do
    %{
      worker_id: worker_id,
      process_pid: Map.get(info, :process_pid),
      pgid: Map.get(info, :pgid),
      process_group?: Map.get(info, :process_group?, false)
    }
  end

  defp to_target(info) when is_map(info) do
    %{
      worker_id: Map.get(info, :worker_id),
      process_pid: Map.get(info, :process_pid),
      pgid: Map.get(info, :pgid),
      process_group?: Map.get(info, :process_group?, false)
    }
  end

  defp kill_targets(targets, signal, process_group_kill?) do
    Enum.each(targets, fn target ->
      case kill_target(target, signal, process_group_kill?) do
        :ok ->
          :ok

        {:error, reason} ->
          SLog.warning(
            @log_category,
            "Failed to send #{signal} to #{format_target(target)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp kill_target(%{process_group?: true, pgid: pgid}, signal, true)
       when is_integer(pgid) do
    ProcessKiller.kill_process_group(pgid, signal)
  end

  defp kill_target(%{process_pid: pid}, signal, _process_group_kill?) when is_integer(pid) do
    ProcessKiller.kill_process(pid, signal)
  end

  defp kill_target(_target, _signal, _process_group_kill?), do: :ok

  defp wait_for_targets(targets, poll_interval_ms, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_targets_loop(targets, poll_interval_ms, deadline)
  end

  defp wait_for_targets_loop(targets, poll_interval_ms, deadline) do
    remaining =
      Enum.filter(targets, fn target ->
        ProcessKiller.process_alive?(target.process_pid)
      end)

    cond do
      remaining == [] ->
        []

      System.monotonic_time(:millisecond) >= deadline ->
        remaining

      true ->
        receive do
        after
          poll_interval_ms -> :ok
        end

        wait_for_targets_loop(remaining, poll_interval_ms, deadline)
    end
  end

  defp emit_telemetry(event, count, run_id) do
    :telemetry.execute(
      event,
      %{count: count},
      %{beam_run_id: run_id, timestamp: System.system_time(:second)}
    )
  end

  defp cleanup_on_stop_timeout_ms do
    Defaults.cleanup_on_stop_timeout_ms()
  end

  defp cleanup_poll_interval_ms do
    Defaults.cleanup_poll_interval_ms()
  end

  defp process_group_kill_enabled? do
    Defaults.process_group_kill_enabled?()
  end

  defp log_incomplete_cleanup([]), do: :ok

  defp log_incomplete_cleanup(still_alive) do
    SLog.warning(
      @log_category,
      "Cleanup incomplete: #{length(still_alive)} processes still alive after SIGKILL"
    )
  end

  defp format_target(%{worker_id: worker_id, process_pid: pid})
       when is_binary(worker_id) and is_integer(pid) do
    "#{worker_id} (pid #{pid})"
  end

  defp format_target(%{process_pid: pid}) when is_integer(pid), do: "pid #{pid}"
  defp format_target(_), do: "unknown target"
end
