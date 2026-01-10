defmodule Snakepit.Test.ProcessLeakTracker do
  @moduledoc false

  @table :snakepit_test_leak_pids

  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public])
      _ -> :ok
    end

    :ok
  end

  def register_pid(pid) when is_integer(pid) do
    init()
    :ets.insert(@table, {pid})
    pid
  end

  def register_port(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> register_pid(pid)
      _ -> :ok
    end
  end

  def unregister_pid(pid) when is_integer(pid) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, pid)
    end

    :ok
  end

  def cleanup!(timeout_ms \\ 2_000) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _table ->
        @table
        |> :ets.tab2list()
        |> Enum.each(fn {pid} ->
          if Snakepit.ProcessKiller.process_alive?(pid) do
            _ = Snakepit.ProcessKiller.kill_with_escalation(pid, timeout_ms)
          end
        end)
    end

    :ok
  end
end
