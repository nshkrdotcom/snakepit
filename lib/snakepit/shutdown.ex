defmodule Snakepit.Shutdown do
  @moduledoc false

  alias Snakepit.Defaults
  alias Snakepit.Internal.TimeoutRunner
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
  @type shutdown_marker :: false | {pid(), reference()} | true

  @type cleanup_result :: :ok | :timeout | :skipped | {:error, term()}

  @doc false
  @spec in_progress?() :: boolean()
  def in_progress? do
    shutdown_mark_active?() or system_stopping?()
  end

  @doc false
  def mark_in_progress do
    marker = {self(), make_ref()}
    :persistent_term.put(@shutdown_flag_key, marker)
    spawn_shutdown_marker_watcher(marker)
    :ok
  end

  @doc false
  def clear_in_progress do
    :persistent_term.put(@shutdown_flag_key, false)
    :ok
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

  @doc false
  @spec stop_supervisor(pid() | atom(), keyword()) :: :ok
  def stop_supervisor(supervisor, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 0) || 0
    label = Keyword.get(opts, :label, "Shutdown")
    app = Keyword.get(opts, :app, :snakepit)
    stop_fun = Keyword.get(opts, :stop_fun, &Application.stop/1)

    case resolve_supervisor_pid(supervisor) do
      nil ->
        invoke_stop_fun(stop_fun, app)
        SLog.info(:shutdown, "#{label} complete (supervisor already terminated).")

      supervisor_pid ->
        ref = Process.monitor(supervisor_pid)
        invoke_stop_fun(stop_fun, app)

        receive do
          {:DOWN, ^ref, :process, ^supervisor_pid, _reason} ->
            SLog.info(:shutdown, "#{label} complete (confirmed via :DOWN signal).")
        after
          timeout_ms ->
            Process.demonitor(ref, [:flush])

            SLog.warning(
              :shutdown,
              "#{label} confirmation timeout after #{timeout_ms}ms. Proceeding anyway.",
              shutdown_timeout_ms: timeout_ms
            )
        end
    end

    :ok
  end

  defp stop_snakepit(shutdown_timeout, label) do
    stop_supervisor(Snakepit.Supervisor, timeout_ms: shutdown_timeout, label: label)
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
    task_timeout = cleanup_timeout + Defaults.shutdown_margin_ms()

    case run_with_timeout(fn -> cleanup_fun.(entries, opts) end, task_timeout) do
      {:ok, result} ->
        normalize_cleanup_result(result)

      :timeout ->
        SLog.warning(
          :shutdown,
          "Cleanup exceeded #{task_timeout}ms. Skipping remaining cleanup.",
          timeout_ms: task_timeout
        )

        :timeout

      {:error, reason} ->
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

  @spec system_stopping?() :: boolean()
  defp system_stopping? do
    case :init.get_status() do
      {status, init_status} ->
        shutdown_status?(status) or shutdown_status?(init_status)
    end
  rescue
    _ -> false
  end

  @spec shutdown_status?(term()) :: boolean()
  defp shutdown_status?(status) when status in [:stopping, :stopped], do: true
  defp shutdown_status?(_), do: false

  defp run_with_timeout(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    TimeoutRunner.run(fun, timeout_ms)
  end

  defp resolve_supervisor_pid(pid) when is_pid(pid) do
    pid
  end

  defp resolve_supervisor_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_supervisor_pid(_), do: nil

  defp invoke_stop_fun(stop_fun, app) when is_function(stop_fun, 1), do: stop_fun.(app)
  defp invoke_stop_fun(stop_fun, _app) when is_function(stop_fun, 0), do: stop_fun.()

  defp shutdown_mark_active? do
    case :persistent_term.get(@shutdown_flag_key, false) do
      false ->
        false

      # Backward compatibility for legacy boolean markers.
      true ->
        false

      {owner_pid, _token} ->
        is_pid(owner_pid) and Process.alive?(owner_pid)

      _other ->
        false
    end
  end

  defp spawn_shutdown_marker_watcher({owner_pid, token} = marker) do
    spawn(fn ->
      ref = Process.monitor(owner_pid)

      receive do
        {:DOWN, ^ref, :process, ^owner_pid, _reason} ->
          maybe_clear_stale_marker(marker)
      end
    end)

    token
  end

  defp maybe_clear_stale_marker(marker) do
    case :persistent_term.get(@shutdown_flag_key, false) do
      ^marker ->
        :persistent_term.put(@shutdown_flag_key, false)

      _ ->
        :ok
    end
  end
end
