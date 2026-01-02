defmodule Snakepit.Shutdown do
  @moduledoc false

  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.RuntimeCleanup
  alias Snakepit.ScriptExit
  alias Snakepit.ScriptStop

  @telemetry_start [:snakepit, :script, :shutdown, :start]
  @telemetry_stop [:snakepit, :script, :shutdown, :stop]
  @telemetry_cleanup [:snakepit, :script, :shutdown, :cleanup]
  @telemetry_exit [:snakepit, :script, :shutdown, :exit]
  @shutdown_flag_key {__MODULE__, :in_progress}

  @type cleanup_result :: :ok | :timeout | :skipped | {:error, term()}

  @doc false
  def in_progress? do
    :persistent_term.get(@shutdown_flag_key, false) or system_stopping?()
  end

  @doc false
  def mark_in_progress do
    :persistent_term.put(@shutdown_flag_key, true)
  end

  @doc false
  def clear_in_progress do
    :persistent_term.put(@shutdown_flag_key, false)
  end

  @spec run(keyword()) :: :ok
  def run(opts) when is_list(opts) do
    exit_mode = Keyword.fetch!(opts, :exit_mode)
    stop_mode = Keyword.fetch!(opts, :stop_mode)
    owned? = Keyword.fetch!(opts, :owned?)
    status = Keyword.fetch!(opts, :status)

    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, 0) || 0
    cleanup_timeout = Keyword.get(opts, :cleanup_timeout, 0) || 0
    label = Keyword.get(opts, :label, "Shutdown")
    run_id = Keyword.get(opts, :run_id) || safe_run_id()

    telemetry_fun = Keyword.get(opts, :telemetry_fun, &:telemetry.execute/3)
    capture_targets_fun = Keyword.get(opts, :capture_targets_fun, &capture_targets/0)
    stop_fun = Keyword.get(opts, :stop_fun, &stop_snakepit/2)
    cleanup_fun = Keyword.get(opts, :cleanup_fun, &cleanup/2)
    exit_fun = Keyword.get(opts, :exit_fun, &ScriptExit.apply_exit_mode/2)

    metadata_base = %{
      run_id: run_id,
      exit_mode: exit_mode,
      stop_mode: stop_mode,
      owned?: owned?,
      status: status
    }

    stop_snakepit? = ScriptStop.stop_snakepit?(stop_mode, owned?)
    exit_will_stop? = exit_mode in [:halt, :stop]
    cleanup_will_run? = is_integer(cleanup_timeout) and cleanup_timeout > 0
    mark_shutdown? = stop_snakepit? or cleanup_will_run? or exit_will_stop?

    if mark_shutdown? do
      mark_in_progress()
    end

    try do
      emit_telemetry(telemetry_fun, @telemetry_start, metadata_base, :pending)

      targets = if cleanup_will_run?, do: safe_capture_targets(capture_targets_fun), else: []

      if stop_snakepit? do
        stop_fun.(shutdown_timeout, label)
      end

      emit_telemetry(telemetry_fun, @telemetry_stop, metadata_base, :pending)

      cleanup_result = run_cleanup_with_timeout(targets, run_id, cleanup_timeout, cleanup_fun)

      emit_telemetry(telemetry_fun, @telemetry_cleanup, metadata_base, cleanup_result)
      emit_telemetry(telemetry_fun, @telemetry_exit, metadata_base, cleanup_result)

      exit_fun.(exit_mode, status)
      :ok
    after
      if mark_shutdown? do
        clear_in_progress()
      end
    end
  end

  defp emit_telemetry(telemetry_fun, event, metadata_base, cleanup_result) do
    telemetry_fun.(event, %{}, Map.put(metadata_base, :cleanup_result, cleanup_result))
  end

  defp safe_capture_targets(capture_targets_fun) when is_function(capture_targets_fun, 0) do
    capture_targets_fun.()
  catch
    _, _ -> []
  end

  defp capture_targets do
    if Process.whereis(ProcessRegistry) do
      ProcessRegistry.current_run_entries()
    else
      []
    end
  end

  defp stop_snakepit(shutdown_timeout, label) do
    case Process.whereis(Snakepit.Supervisor) do
      nil ->
        Application.stop(:snakepit)
        SLog.info(:shutdown, "#{label} complete (supervisor already terminated).")

      supervisor_pid ->
        ref = Process.monitor(supervisor_pid)
        Application.stop(:snakepit)

        receive do
          {:DOWN, ^ref, :process, ^supervisor_pid, _reason} ->
            SLog.info(:shutdown, "#{label} complete (confirmed via :DOWN signal).")
        after
          shutdown_timeout ->
            SLog.warning(
              :shutdown,
              "#{label} confirmation timeout after #{shutdown_timeout}ms. Proceeding anyway.",
              shutdown_timeout_ms: shutdown_timeout
            )
        end
    end
  end

  defp cleanup(entries, opts) do
    RuntimeCleanup.run(entries, opts)
  end

  defp run_cleanup_with_timeout(_entries, _run_id, cleanup_timeout, _cleanup_fun)
       when cleanup_timeout <= 0 do
    :skipped
  end

  defp run_cleanup_with_timeout(entries, run_id, cleanup_timeout, cleanup_fun) do
    poll_interval_ms = Defaults.cleanup_poll_interval_ms()
    opts = [timeout_ms: cleanup_timeout, poll_interval_ms: poll_interval_ms, run_id: run_id]
    task_timeout = cleanup_timeout + 1_000
    task = Task.async(fn -> cleanup_fun.(entries, opts) end)

    case Task.yield(task, task_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        normalize_cleanup_result(result)

      nil ->
        SLog.warning(
          :shutdown,
          "Cleanup exceeded #{task_timeout}ms. Skipping remaining cleanup.",
          timeout_ms: task_timeout
        )

        :timeout

      {:exit, reason} ->
        SLog.warning(:shutdown, "Cleanup crashed: #{inspect(reason)}", reason: reason)
        {:error, reason}
    end
  end

  defp normalize_cleanup_result(:ok), do: :ok
  defp normalize_cleanup_result(:skipped), do: :skipped
  defp normalize_cleanup_result({:timeout, _}), do: :timeout
  defp normalize_cleanup_result({:error, _} = error), do: error
  defp normalize_cleanup_result(other), do: other

  defp safe_run_id do
    ProcessRegistry.get_beam_run_id()
  catch
    _, _ -> nil
  end

  defp system_stopping? do
    case :init.get_status() do
      {status, init_status} ->
        shutdown_status?(status) or shutdown_status?(init_status)
    end
  rescue
    _ -> false
  end

  defp shutdown_status?(status) when status in [:stopping, :stopped], do: true
  defp shutdown_status?(_), do: false
end
