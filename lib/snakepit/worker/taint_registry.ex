defmodule Snakepit.Worker.TaintRegistry do
  @moduledoc """
  Tracks tainted workers and devices after crash classification.
  """

  @table :snakepit_worker_taints
  @table_opts [:named_table, :set, :public, {:read_concurrency, true}]

  def taint_worker(worker_id, opts) when is_binary(worker_id) do
    ensure_table()
    now_ms = System.monotonic_time(:millisecond)
    duration = Keyword.get(opts, :duration_ms, 60_000)

    record = %{
      tainted_until: now_ms + duration,
      reason: Keyword.get(opts, :reason),
      exit_code: Keyword.get(opts, :exit_code),
      device: Keyword.get(opts, :device),
      crashed_at: now_ms,
      restart_notified: false
    }

    :ets.insert(@table, {worker_id, record})
    :ok
  end

  def worker_tainted?(worker_id) when is_binary(worker_id) do
    ensure_table()

    case :ets.lookup(@table, worker_id) do
      [{^worker_id, record}] ->
        if expired?(record) do
          :ets.delete(@table, worker_id)
          false
        else
          true
        end

      _ ->
        false
    end
  end

  def worker_info(worker_id) when is_binary(worker_id) do
    ensure_table()

    case :ets.lookup(@table, worker_id) do
      [{^worker_id, record}] ->
        if expired?(record) do
          :ets.delete(@table, worker_id)
          :error
        else
          {:ok, record}
        end

      _ ->
        :error
    end
  end

  def consume_restart(worker_id) when is_binary(worker_id) do
    ensure_table()

    case :ets.lookup(@table, worker_id) do
      [{^worker_id, record}] ->
        cond do
          expired?(record) ->
            :ets.delete(@table, worker_id)
            :error

          record.restart_notified ->
            :error

          true ->
            updated = Map.put(record, :restart_notified, true)
            :ets.insert(@table, {worker_id, updated})
            {:ok, record}
        end

      _ ->
        :error
    end
  end

  def clear_worker(worker_id) when is_binary(worker_id) do
    ensure_table()
    :ets.delete(@table, worker_id)
    :ok
  end

  defp expired?(record) do
    now_ms = System.monotonic_time(:millisecond)
    now_ms > Map.get(record, :tainted_until, 0)
  end

  defp ensure_table do
    Snakepit.ETSOwner.ensure_table(@table, @table_opts)
  end
end
