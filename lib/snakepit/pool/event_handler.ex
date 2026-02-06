defmodule Snakepit.Pool.EventHandler do
  @moduledoc false

  alias Snakepit.CrashBarrier
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.ClientReply
  alias Snakepit.Pool.Queue
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.State

  @log_category :pool

  def handle_queue_timeout(state, pool_name, from) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:noreply, state}

      pool_state ->
        now = System.monotonic_time(:millisecond)
        retention_ms = Queue.cancellation_retention_ms(pool_state.queue_timeout)

        {pruned_queue, dropped?} =
          Queue.drop_request_from_queue(pool_state.request_queue, from)

        if dropped? do
          GenServer.reply(from, {:error, :queue_timeout})

          SLog.debug(
            @log_category,
            "Removed timed out request #{inspect(from)} from queue in pool #{pool_name}"
          )

          new_cancelled =
            Queue.record_cancelled_request(pool_state.cancelled_requests, from, now, retention_ms)

          updated_stats = Map.update!(pool_state.stats, :queue_timeouts, &(&1 + 1))

          updated_pool_state = %{
            pool_state
            | request_queue: pruned_queue,
              cancelled_requests: new_cancelled,
              stats: updated_stats
          }

          updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
          {:noreply, %{state | pools: updated_pools}}
        else
          SLog.debug(
            @log_category,
            "Queue timeout fired for #{inspect(from)} in pool #{pool_name} after request was already handled"
          )

          {:noreply, state}
        end
    end
  end

  def handle_down(state, pid, reason) do
    case PoolRegistry.get_worker_id_by_pid(pid) do
      {:error, :not_found} ->
        {:noreply, state}

      {:ok, worker_id} ->
        handle_worker_down(state, worker_id, pid, reason)
    end
  end

  def handle_checkin(state, pool_name, worker_id, decrement?, context) do
    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error(@log_category, "checkin_worker: pool #{pool_name} not found!")
        {:noreply, state}

      pool_state ->
        process_checkin(pool_name, worker_id, pool_state, state, decrement?, context)
    end
  end

  defp handle_worker_down(state, worker_id, pid, reason) do
    SLog.error(
      @log_category,
      "Worker #{worker_id} (pid: #{inspect(pid)}) died: #{inspect(reason)}"
    )

    :ets.match_delete(state.affinity_cache, {:_, worker_id, :_})

    pool_name = Snakepit.Pool.extract_pool_name_from_worker_id(worker_id)

    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.warning(
          @log_category,
          "Dead worker #{worker_id} belongs to unknown pool #{pool_name}"
        )

        {:noreply, state}

      pool_state ->
        maybe_taint_on_crash(pool_name, worker_id, reason, pool_state)

        updated_state =
          state
          |> remove_worker_from_pool(pool_name, pool_state, worker_id)
          |> tap(fn _ ->
            SLog.debug(@log_category, "Removed dead worker #{worker_id} from pool #{pool_name}")
          end)

        {:noreply, updated_state}
    end
  end

  defp maybe_taint_on_crash(pool_name, worker_id, reason, pool_state) do
    crash_config = CrashBarrier.config(pool_state.pool_config)

    with true <- CrashBarrier.enabled?(crash_config),
         {:ok, info} <- CrashBarrier.crash_info({:error, {:worker_exit, reason}}, crash_config) do
      maybe_taint_worker(pool_name, worker_id, info, crash_config)
    else
      _ -> :ok
    end
  end

  defp maybe_taint_worker(pool_name, worker_id, info, crash_config) do
    if CrashBarrier.worker_tainted?(worker_id) do
      :ok
    else
      CrashBarrier.taint_worker(pool_name, worker_id, info, crash_config)
    end
  end

  defp remove_worker_from_pool(state, pool_name, pool_state, worker_id) do
    new_workers = List.delete(pool_state.workers, worker_id)
    new_available = MapSet.delete(pool_state.available, worker_id)
    new_ready_workers = MapSet.delete(pool_state.ready_workers, worker_id)
    new_loads = Map.delete(pool_state.worker_loads, worker_id)
    new_capacities = Map.delete(pool_state.worker_capacities, worker_id)

    updated_pool_state = %{
      pool_state
      | workers: new_workers,
        available: new_available,
        ready_workers: new_ready_workers,
        worker_loads: new_loads,
        worker_capacities: new_capacities
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    %{state | pools: updated_pools}
  end

  defp process_checkin(pool_name, worker_id, pool_state, state, decrement?, context) do
    now = System.monotonic_time(:millisecond)
    retention_ms = Queue.cancellation_retention_ms(pool_state.queue_timeout)

    pruned_cancelled =
      Queue.prune_cancelled_requests(pool_state.cancelled_requests, now, retention_ms)

    pool_state =
      if decrement? do
        updated_pool_state = State.decrement_worker_load(pool_state, worker_id)
        context.maybe_track_capacity.(updated_pool_state, worker_id, :decrement)
        updated_pool_state
      else
        pool_state
      end

    process_next_queued_request(
      pool_name,
      worker_id,
      pool_state,
      pruned_cancelled,
      state,
      context
    )
  end

  defp process_next_queued_request(
         pool_name,
         worker_id,
         pool_state,
         pruned_cancelled,
         state,
         context
       ) do
    case context.select_queue_worker.(pool_state, worker_id) do
      {:ok, queue_worker} ->
        case Queue.pop_request_for_worker(pool_state.request_queue, queue_worker) do
          {:empty, _queue} ->
            updated_pool_state = %{pool_state | cancelled_requests: pruned_cancelled}
            updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
            {:noreply, %{state | pools: updated_pools}}

          {request, new_queue} ->
            handle_queued_request(
              pool_name,
              queue_worker,
              pool_state,
              request,
              new_queue,
              pruned_cancelled,
              state,
              context
            )
        end

      :no_worker ->
        updated_pool_state = %{pool_state | cancelled_requests: pruned_cancelled}
        updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
        {:noreply, %{state | pools: updated_pools}}
    end
  end

  defp handle_queued_request(
         pool_name,
         worker_id,
         pool_state,
         request,
         new_queue,
         pruned_cancelled,
         state,
         context
       ) do
    {queued_from, command, args, opts, _queued_at, timer_ref} = normalize_request(request)
    Queue.cancel_queue_timer(timer_ref)

    ctx = %{
      pool_name: pool_name,
      worker_id: worker_id,
      pool_state: pool_state,
      queued_from: queued_from,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state,
      context: context
    }

    if Map.has_key?(pruned_cancelled, queued_from) do
      handle_cancelled_request(ctx)
    else
      handle_valid_request(ctx, command, args, opts)
    end
  end

  defp handle_cancelled_request(ctx) do
    %{
      pool_name: pool_name,
      worker_id: worker_id,
      pool_state: pool_state,
      queued_from: queued_from,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state
    } = ctx

    SLog.debug(@log_category, "Skipping cancelled request from #{inspect(queued_from)}")
    new_cancelled = Queue.drop_cancelled_request(pruned_cancelled, queued_from)

    updated_pool_state = %{
      pool_state
      | request_queue: new_queue,
        cancelled_requests: new_cancelled
    }

    GenServer.cast(self(), {:checkin_worker, pool_name, worker_id, :skip_decrement})
    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp handle_valid_request(ctx, command, args, opts) do
    %{queued_from: queued_from} = ctx
    {client_pid, _tag} = queued_from

    execute_queued_request(ctx, client_pid, command, args, opts)
  end

  defp execute_queued_request(ctx, client_pid, command, args, opts) do
    %{
      pool_name: pool_name,
      worker_id: worker_id,
      queued_from: queued_from,
      pool_state: pool_state,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state,
      context: context
    } = ctx

    pool_state = State.increment_worker_load(pool_state, worker_id)
    context.maybe_track_capacity.(pool_state, worker_id, :increment)
    pool_pid = self()

    context.async_with_context.(fn ->
      ref = Process.monitor(client_pid)

      case monitor_client_status(ref, client_pid) do
        {:down, _reason} ->
          Process.demonitor(ref, [:flush])
          context.maybe_checkin_worker.(pool_name, worker_id)

        :alive ->
          {result, final_worker_id} =
            context.execute_with_crash_barrier.(
              pool_pid,
              pool_name,
              worker_id,
              command,
              args,
              opts,
              pool_state.pool_config
            )

          checkin_worker_id = final_worker_id

          ClientReply.reply_and_checkin(
            pool_name,
            checkin_worker_id,
            queued_from,
            ref,
            client_pid,
            result,
            context.maybe_checkin_worker
          )
      end
    end)

    updated_pool_state = %{
      pool_state
      | request_queue: new_queue,
        cancelled_requests: pruned_cancelled
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp monitor_client_status(ref, client_pid) do
    case await_client_down(ref, client_pid) do
      :alive ->
        if Process.alive?(client_pid), do: :alive, else: {:down, :unknown}

      other ->
        other
    end
  end

  defp await_client_down(ref, client_pid) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, reason} -> {:down, reason}
    after
      0 -> :alive
    end
  end

  defp normalize_request({from, command, args, opts, queued_at, timer_ref}) do
    {from, command, args, opts, queued_at, timer_ref}
  end

  defp normalize_request({from, command, args, opts, queued_at, timer_ref, _affinity_worker_id}) do
    {from, command, args, opts, queued_at, timer_ref}
  end
end
