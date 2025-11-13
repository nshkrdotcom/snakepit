defmodule Snakepit.Test.CommandRunner do
  @moduledoc """
  Deterministic command runner for tests.

  Each invocation consumes a queued result (defaults to `:ok`). Results can be
  atoms, `{:error, reason}` tuples, or functions receiving `{command, args, opts}`.
  """

  @behaviour Snakepit.Bootstrap.Runner

  def reset!(results \\ []) do
    Process.put(state_key(), %{calls: [], results: List.wrap(results)})
    :ok
  end

  def calls do
    Process.get(state_key(), %{calls: []}).calls |> Enum.reverse()
  end

  def push_result(result) do
    update_state(fn state ->
      %{state | results: state.results ++ [result]}
    end)
  end

  @impl true
  def mix(task, args) do
    record({:mix, task, args})
    consume_result({:mix, task, args, []})
  end

  @impl true
  def cmd(command, args, opts) do
    record({:cmd, command, args, opts})
    consume_result({:cmd, command, args, opts})
  end

  defp consume_result(call) do
    current = Process.get(state_key(), %{calls: [], results: []})

    case current.results do
      [next | rest] ->
        Process.put(state_key(), %{current | results: rest})
        translate(next, call)

      [] ->
        translate(:ok, call)
    end
  end

  defp translate(:ok, _call), do: :ok
  defp translate({:error, reason}, _call), do: {:error, reason}

  defp translate(fun, call) when is_function(fun, 1) do
    fun.(call)
  end

  defp translate(fun, {type, command, args, opts}) when is_function(fun, 4) do
    fun.(type, command, args, opts)
  end

  defp translate(other, _call), do: other

  defp record(entry) do
    update_state(fn state ->
      %{state | calls: [entry | state.calls]}
    end)
  end

  defp state_key, do: {__MODULE__, self()}

  defp update_state(fun) do
    current = Process.get(state_key(), %{calls: [], results: []})
    new_state = fun.(current)
    Process.put(state_key(), new_state)
    new_state
  end
end
