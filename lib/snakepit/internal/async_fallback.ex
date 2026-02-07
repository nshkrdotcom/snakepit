defmodule Snakepit.Internal.AsyncFallback do
  @moduledoc """
  Supervised task helpers with automatic fallback to bare monitors.

  When `TaskSupervisor` is unavailable (not yet started or crashed), these
  helpers fall back to `spawn_monitor` instead of crashing the caller.
  """

  @type monitored_task :: {:ok, pid(), reference()}
  @type fallback_mode :: :monitored | :fire_and_forget
  @type fallback_reason :: {:rescue, term()} | {:exit, term()}

  @spec start_monitored((-> term())) :: monitored_task()
  def start_monitored(fun) when is_function(fun, 0) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          {:snakepit_run_task, monitor_ref} ->
            result = fun.()
            send(parent, {monitor_ref, result})
        end
      end)

    send(pid, {:snakepit_run_task, ref})
    {:ok, pid, ref}
  end

  @spec start_monitored_fire_and_forget((-> term())) :: {pid(), reference()}
  def start_monitored_fire_and_forget(fun) when is_function(fun, 0) do
    spawn_monitor(fun)
  end

  @spec start_nolink_with_fallback(
          Supervisor.supervisor(),
          (-> term()),
          keyword()
        ) :: monitored_task()
  def start_nolink_with_fallback(task_supervisor, fun, opts \\ [])
      when is_function(fun, 0) and is_list(opts) do
    fallback_mode = Keyword.get(opts, :fallback_mode, :monitored)
    on_fallback = Keyword.get(opts, :on_fallback, fn _reason -> :ok end)

    try do
      task = Task.Supervisor.async_nolink(task_supervisor, fun)
      {:ok, task.pid, task.ref}
    rescue
      error ->
        on_fallback.({:rescue, error})
        start_fallback(fallback_mode, fun)
    catch
      :exit, reason ->
        on_fallback.({:exit, reason})
        start_fallback(fallback_mode, fun)
    end
  end

  @spec start_child_with_fallback(
          Supervisor.supervisor(),
          (-> term()),
          keyword()
        ) :: :ok
  def start_child_with_fallback(task_supervisor, fun, opts \\ [])
      when is_function(fun, 0) and is_list(opts) do
    on_fallback = Keyword.get(opts, :on_fallback, fn _reason -> :ok end)

    try do
      _ = Task.Supervisor.start_child(task_supervisor, fun)
      :ok
    rescue
      error ->
        on_fallback.({:rescue, error})
        _ = start_monitored_fire_and_forget(fun)
        :ok
    catch
      :exit, reason ->
        on_fallback.({:exit, reason})
        _ = start_monitored_fire_and_forget(fun)
        :ok
    end
  end

  defp start_fallback(:monitored, fun), do: start_monitored(fun)

  defp start_fallback(:fire_and_forget, fun),
    do: to_monitored_task(start_monitored_fire_and_forget(fun))

  defp start_fallback(_, fun), do: start_monitored(fun)

  defp to_monitored_task({pid, ref}) when is_pid(pid) and is_reference(ref), do: {:ok, pid, ref}
end
