defmodule Snakepit.Pool.Scheduler do
  @moduledoc false

  def handle_no_workers_available(pool_name, pool_state, command, args, opts, from, state) do
    current_queue_size = :queue.len(pool_state.request_queue)

    if current_queue_size >= pool_state.max_queue_size do
      handle_pool_saturated(pool_name, pool_state, current_queue_size, state)
    else
      queue_request(pool_name, pool_state, command, args, opts, from, state)
    end
  end

  defp handle_pool_saturated(pool_name, pool_state, current_queue_size, state) do
    updated_pool_state = %{
      pool_state
      | stats: Map.update!(pool_state.stats, :pool_saturated, &(&1 + 1))
    }

    :telemetry.execute(
      [:snakepit, :pool, :saturated],
      %{queue_size: current_queue_size, max_queue_size: pool_state.max_queue_size},
      %{
        pool: pool_name,
        available_workers: MapSet.size(pool_state.available),
        busy_workers: busy_worker_count(pool_state)
      }
    )

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:reply, {:error, :pool_saturated}, %{state | pools: updated_pools}}
  end

  defp queue_request(pool_name, pool_state, command, args, opts, from, state) do
    timer_ref =
      Process.send_after(self(), {:queue_timeout, pool_name, from}, pool_state.queue_timeout)

    request = {from, command, args, opts, System.monotonic_time(), timer_ref}
    new_queue = :queue.in(request, pool_state.request_queue)

    updated_stats =
      pool_state.stats
      |> Map.update!(:requests, &(&1 + 1))
      |> Map.update!(:queued, &(&1 + 1))

    updated_pool_state = %{
      pool_state
      | request_queue: new_queue,
        stats: updated_stats
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp busy_worker_count(pool_state) do
    map_size(pool_state.worker_loads)
  end
end
