defmodule Snakepit.Pool.Queue do
  @moduledoc false

  alias Snakepit.Defaults

  def compact_pool_queue(queue, cancelled_requests, queue_timeout) do
    now_ms = System.monotonic_time(:millisecond)
    compact_pool_queue(queue, cancelled_requests, queue_timeout, now_ms)
  end

  def compact_pool_queue(queue, cancelled_requests, queue_timeout, now_ms)
      when is_integer(now_ms) do
    retention_ms = cancellation_retention_ms(queue_timeout)
    compact_request_queue(queue, cancelled_requests, now_ms, retention_ms)
  end

  def compact_pool_queue(queue, cancelled_requests, queue_timeout, _now_ms) do
    compact_pool_queue(queue, cancelled_requests, queue_timeout)
  end

  def drop_request_from_queue(queue, from) do
    {remaining, dropped?} =
      queue
      |> :queue.to_list()
      |> Enum.reduce({[], false}, fn request, {acc, dropped?} ->
        {queued_from, timer_ref} = request_from_and_timer(request)

        if queued_from == from do
          cancel_queue_timer(timer_ref)
          {acc, true}
        else
          {[request | acc], dropped?}
        end
      end)

    new_queue =
      remaining
      |> Enum.reverse()
      |> :queue.from_list()

    {new_queue, dropped?}
  end

  def prune_cancelled_requests(cancelled_requests, _now_ms, _retention_ms)
      when cancelled_requests == %{} do
    cancelled_requests
  end

  def prune_cancelled_requests(cancelled_requests, now_ms, retention_ms) do
    cutoff = now_ms - retention_ms

    cancelled_requests
    |> Enum.reject(fn {_from, recorded_at} -> recorded_at < cutoff end)
    |> Map.new()
  end

  def cancellation_retention_ms(queue_timeout)
      when is_integer(queue_timeout) and queue_timeout > 0 do
    retention = queue_timeout * Defaults.pool_cancelled_retention_multiplier()
    max(retention, queue_timeout)
  end

  def cancellation_retention_ms(_queue_timeout) do
    Defaults.pool_queue_timeout() * Defaults.pool_cancelled_retention_multiplier()
  end

  def record_cancelled_request(cancelled_requests, from, now_ms, retention_ms) do
    cancelled_requests
    |> prune_cancelled_requests(now_ms, retention_ms)
    |> Map.put(from, now_ms)
    |> trim_cancelled_requests()
  end

  def drop_cancelled_request(cancelled_requests, from) do
    Map.delete(cancelled_requests, from)
  end

  def cancel_queue_timer(nil), do: :ok

  def cancel_queue_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  def pop_request_for_worker(queue, worker_id) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:empty, queue}

      {{:value, request}, rest} ->
        if request_compatible?(request, worker_id) do
          {request, rest}
        else
          list = [request | :queue.to_list(rest)]

          case pop_request_for_worker_from_list(list, worker_id) do
            {:ok, found, remaining} ->
              {found, :queue.from_list(remaining)}

            :empty ->
              {:empty, queue}
          end
        end
    end
  end

  defp compact_request_queue(queue, cancelled_requests, now_ms, retention_ms) do
    pruned_cancelled = prune_cancelled_requests(cancelled_requests, now_ms, retention_ms)

    {filtered, updated_cancelled} =
      queue
      |> :queue.to_list()
      |> Enum.reduce({[], pruned_cancelled}, fn request, {acc, current_cancelled} ->
        {from, timer_ref} = request_from_and_timer(request)

        cond do
          Map.has_key?(current_cancelled, from) ->
            cancel_queue_timer(timer_ref)
            {acc, drop_cancelled_request(current_cancelled, from)}

          not alive_from?(from) ->
            cancel_queue_timer(timer_ref)
            {acc, drop_cancelled_request(current_cancelled, from)}

          true ->
            {[request | acc], current_cancelled}
        end
      end)

    new_queue =
      filtered
      |> Enum.reverse()
      |> :queue.from_list()

    {new_queue, updated_cancelled}
  end

  defp alive_from?({pid, _ref}) when is_pid(pid), do: Process.alive?(pid)
  defp alive_from?(_), do: false

  defp pop_request_for_worker_from_list(list, worker_id) do
    do_pop_request_for_worker(list, worker_id, [])
  end

  defp do_pop_request_for_worker([], _worker_id, _acc), do: :empty

  defp do_pop_request_for_worker([request | rest], worker_id, acc) do
    if request_compatible?(request, worker_id) do
      {:ok, request, Enum.reverse(acc, rest)}
    else
      do_pop_request_for_worker(rest, worker_id, [request | acc])
    end
  end

  defp request_compatible?(request, worker_id) do
    case request_affinity_worker_id(request) do
      nil -> true
      ^worker_id -> true
      _ -> false
    end
  end

  defp request_affinity_worker_id(
         {_from, _command, _args, _opts, _queued_at, _timer_ref, affinity}
       ) do
    affinity
  end

  defp request_affinity_worker_id({_from, _command, _args, _opts, _queued_at, _timer_ref}) do
    nil
  end

  defp request_from_and_timer({from, _command, _args, _opts, _queued_at, timer_ref}),
    do: {from, timer_ref}

  defp request_from_and_timer({from, _command, _args, _opts, _queued_at, timer_ref, _affinity}) do
    {from, timer_ref}
  end

  defp trim_cancelled_requests(cancelled_requests) do
    max_entries = Defaults.pool_max_cancelled_entries()

    if map_size(cancelled_requests) <= max_entries do
      cancelled_requests
    else
      entries_to_keep = max_entries
      drop_count = map_size(cancelled_requests) - entries_to_keep

      cancelled_requests
      |> Enum.sort_by(fn {_from, recorded_at} -> recorded_at end)
      |> Enum.drop(drop_count)
      |> Map.new()
    end
  end
end
