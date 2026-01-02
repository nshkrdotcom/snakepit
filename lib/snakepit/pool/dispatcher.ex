defmodule Snakepit.Pool.Dispatcher do
  @moduledoc false

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Queue
  alias Snakepit.Pool.Scheduler

  @log_category :pool

  def execute(state, pool_name, command, args, opts, from, context) do
    with {:ok, pool_state} <- get_pool(state.pools, pool_name),
         :ok <- check_pool_initialized(pool_state) do
      handle_execute_in_pool(pool_name, pool_state, command, args, opts, from, state, context)
    else
      {:error, :pool_not_found} ->
        {:reply, {:error, {:pool_not_found, pool_name}}, state}

      {:error, :pool_not_initialized} ->
        {:reply, {:error, :pool_not_initialized}, state}
    end
  end

  defp get_pool(pools, pool_name) do
    case Map.get(pools, pool_name) do
      nil -> {:error, :pool_not_found}
      pool_state -> {:ok, pool_state}
    end
  end

  defp check_pool_initialized(pool_state) do
    if pool_state.initialized, do: :ok, else: {:error, :pool_not_initialized}
  end

  defp handle_execute_in_pool(pool_name, pool_state, command, args, opts, from, state, context) do
    {request_queue, cancelled_requests} =
      case opts[:__test_now_ms] do
        now_ms when is_integer(now_ms) ->
          Queue.compact_pool_queue(
            pool_state.request_queue,
            pool_state.cancelled_requests,
            pool_state.queue_timeout,
            now_ms
          )

        _ ->
          Queue.compact_pool_queue(
            pool_state.request_queue,
            pool_state.cancelled_requests,
            pool_state.queue_timeout
          )
      end

    pool_state = %{
      pool_state
      | request_queue: request_queue,
        cancelled_requests: cancelled_requests
    }

    session_id = opts[:session_id]

    case context.checkout_worker.(pool_state, session_id, state.affinity_cache) do
      {:ok, worker_id, new_pool_state} ->
        execute_with_worker(
          pool_name,
          worker_id,
          new_pool_state,
          command,
          args,
          opts,
          from,
          state,
          context
        )

      {:error, :no_workers} ->
        Scheduler.handle_no_workers_available(
          pool_name,
          pool_state,
          command,
          args,
          opts,
          from,
          state
        )
    end
  end

  defp execute_with_worker(
         pool_name,
         worker_id,
         new_pool_state,
         command,
         args,
         opts,
         from,
         state,
         context
       ) do
    spawn_execution_task(
      pool_name,
      worker_id,
      command,
      args,
      opts,
      from,
      new_pool_state.pool_config,
      context
    )

    updated_pool_state = %{
      new_pool_state
      | stats: Map.update!(new_pool_state.stats, :requests, &(&1 + 1))
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp spawn_execution_task(pool_name, worker_id, command, args, opts, from, pool_config, context) do
    context.async_with_context.(fn ->
      {client_pid, _tag} = from
      ref = Process.monitor(client_pid)
      start_time = System.monotonic_time(:microsecond)

      case monitor_client_status(ref, client_pid) do
        {:down, reason} ->
          handle_client_already_down(
            pool_name,
            worker_id,
            command,
            ref,
            start_time,
            reason,
            context
          )

        :alive ->
          exec_ctx = %{
            pool_pid: self(),
            pool_name: pool_name,
            worker_id: worker_id,
            command: command,
            args: args,
            opts: opts,
            from: from,
            ref: ref,
            client_pid: client_pid,
            pool_config: pool_config
          }

          handle_client_alive(exec_ctx, start_time, context)
      end
    end)
  end

  defp handle_client_already_down(
         pool_name,
         worker_id,
         command,
         ref,
         start_time,
         reason,
         context
       ) do
    Process.demonitor(ref, [:flush])
    duration_us = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:snakepit, :request, :executed],
      %{duration_us: duration_us},
      %{
        pool: pool_name,
        worker_id: worker_id,
        command: command,
        success: false,
        aborted: true,
        reason: :client_down,
        client_down_reason: reason
      }
    )

    SLog.debug(@log_category, "Client was already down; skipping work on worker #{worker_id}")
    context.maybe_checkin_worker.(pool_name, worker_id)
  end

  defp handle_client_alive(exec_ctx, start_time, context) do
    %{
      pool_pid: pool_pid,
      pool_name: pool_name,
      worker_id: worker_id,
      command: command,
      args: args,
      opts: opts,
      from: from,
      ref: ref,
      client_pid: client_pid,
      pool_config: pool_config
    } = exec_ctx

    {result, final_worker_id} =
      context.execute_with_crash_barrier.(
        pool_pid,
        pool_name,
        worker_id,
        command,
        args,
        opts,
        pool_config
      )

    telemetry_worker_id = final_worker_id || worker_id
    duration_us = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:snakepit, :request, :executed],
      %{duration_us: duration_us},
      %{
        pool: pool_name,
        worker_id: telemetry_worker_id,
        command: command,
        success: match?({:ok, _}, result)
      }
    )

    handle_client_reply(pool_name, final_worker_id, from, ref, client_pid, result, context)
  end

  defp handle_client_reply(pool_name, worker_id, from, ref, client_pid, result, context) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, _reason} ->
        SLog.warning(
          @log_category,
          "Client #{inspect(client_pid)} died before receiving reply. " <>
            "Checking in worker #{inspect(worker_id)}."
        )

        context.maybe_checkin_worker.(pool_name, worker_id)
    after
      0 ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        context.maybe_checkin_worker.(pool_name, worker_id)
    end
  end

  def monitor_client_status(ref, client_pid) do
    if Process.alive?(client_pid) do
      await_client_down(ref, client_pid)
    else
      case await_client_down(ref, client_pid) do
        :alive -> {:down, :unknown}
        other -> other
      end
    end
  end

  defp await_client_down(ref, client_pid) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, reason} -> {:down, reason}
    after
      0 -> :alive
    end
  end
end
