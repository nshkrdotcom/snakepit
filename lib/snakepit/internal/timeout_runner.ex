defmodule Snakepit.Internal.TimeoutRunner do
  @moduledoc false

  @spec run((-> term()), non_neg_integer()) :: {:ok, term()} | :timeout | {:error, term()}
  def run(fun, timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms >= 0 do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {result_ref, fun.()})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        maybe_recover_normal_down_result(result_ref, reason)
    after
      timeout_ms ->
        case consume_boundary_result(pid, monitor_ref, result_ref) do
          :none ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
            after
              0 -> :ok
            end

            Process.demonitor(monitor_ref, [:flush])
            :timeout

          result ->
            result
        end
    end
  end

  defp maybe_recover_normal_down_result(result_ref, :normal) do
    receive do
      {^result_ref, result} ->
        {:ok, result}
    after
      0 ->
        {:error, :normal}
    end
  end

  defp maybe_recover_normal_down_result(_result_ref, reason), do: {:error, reason}

  defp consume_boundary_result(pid, monitor_ref, result_ref) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        maybe_recover_normal_down_result(result_ref, reason)
    after
      0 ->
        :none
    end
  end
end
