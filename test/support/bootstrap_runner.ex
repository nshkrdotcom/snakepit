defmodule Snakepit.Test.BootstrapRunner do
  @moduledoc """
  Test helper implementing the bootstrap runner behaviour.

  It records every command invocation in the current process so tests can
  assert ordering without running real system commands.
  """

  @behaviour Snakepit.Bootstrap.Runner

  def reset! do
    Process.put(calls_key(), [])
    Process.delete(fail_key())
    :ok
  end

  def calls do
    Process.get(calls_key(), []) |> Enum.reverse()
  end

  def fail_next(reason \\ :error) do
    Process.put(fail_key(), reason)
    :ok
  end

  @impl true
  def mix(task, args) do
    record({:mix, task, args})
    maybe_fail()
  end

  @impl true
  def cmd(command, args, opts) do
    record({:cmd, command, args, opts})
    maybe_fail()
  end

  defp record(entry) do
    Process.put(calls_key(), [entry | Process.get(calls_key(), [])])
    :ok
  end

  defp maybe_fail do
    case Process.delete(fail_key()) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp calls_key, do: {__MODULE__, :calls}
  defp fail_key, do: {__MODULE__, :fail_next}
end
