defmodule Snakepit.Internal.AsyncFallback do
  @moduledoc false

  @type monitored_task :: {:ok, pid(), reference()}

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
end
