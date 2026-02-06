defmodule Snakepit.Worker.LifecycleManager do
  @moduledoc """
  Worker lifecycle manager for automatic recycling and health monitoring.

  Manages worker lifecycle events:
  - **TTL-based recycling**: Recycle workers after configured time
  - **Request-count recycling**: Recycle after N requests
  - **Memory monitoring**: Recycle when the BEAM worker process exceeds a configurable threshold (optional)
  - **Health checks**: Monitor worker health and restart if needed

  ## Why Worker Recycling?

  Long-running Python processes can accumulate memory due to:
  - Memory fragmentation
  - Cache growth
  - Subtle memory leaks in C libraries
  - ML model weight accumulation

  Automatic recycling prevents these issues from impacting production. The current
  implementation samples the BEAM `Snakepit.GRPCWorker` process memory via
  `:get_memory_usage`; Python child process memory is not yet measured directly.

  ## Configuration

      config :snakepit,
        pools: [
          %{
            name: :hpc_pool,
            worker_profile: :thread,
            worker_ttl: {3600, :seconds},      # Recycle hourly
            worker_max_requests: 1000,          # Or after 1000 requests
            memory_threshold_mb: 2048           # Or at 2GB (optional)
          }
        ]

  ## Usage

  The LifecycleManager runs automatically when started in the supervision tree.
  It monitors all workers across all pools.

      # Manual worker recycling
      Snakepit.Worker.LifecycleManager.recycle_worker(pool_name, worker_id)

      # Get lifecycle statistics
      Snakepit.Worker.LifecycleManager.get_stats()

  ## Implementation

  - Runs periodic health checks (every 60 seconds)
  - Tracks worker metadata (start time, request count)
  - Gracefully replaces workers when recycling
  - Emits telemetry events for monitoring
  """

  use GenServer
  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.Internal.AsyncFallback
  alias Snakepit.Internal.TimeoutRunner
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Worker.LifecycleConfig

  @log_category :worker

  @enforce_keys [:workers, :memory_recycle_counts]
  defstruct [
    :workers,
    :check_ref,
    :health_ref,
    :memory_recycle_counts,
    :lifecycle_task_ref,
    :lifecycle_task_pid,
    recycle_task_refs: %{}
  ]

  # Client API

  @doc """
  Start the lifecycle manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a worker for lifecycle management.

  Called automatically when workers start.
  """
  def track_worker(pool_name, worker_id, worker_pid, config) do
    GenServer.cast(__MODULE__, {:track, pool_name, worker_id, worker_pid, config})
  end

  @doc """
  Untrack a worker (called when worker stops).
  """
  def untrack_worker(worker_id) do
    GenServer.cast(__MODULE__, {:untrack, worker_id})
  end

  @doc """
  Manually recycle a worker.
  """
  def recycle_worker(pool_name, worker_id) do
    GenServer.call(__MODULE__, {:recycle, pool_name, worker_id})
  end

  @doc """
  Increment request count for a worker.

  Called after each successful request.
  """
  def increment_request_count(worker_id) do
    GenServer.cast(__MODULE__, {:increment_requests, worker_id})
  end

  @doc """
  Get lifecycle statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Returns a map of pools to the number of memory-threshold-based recycles observed
  since the lifecycle manager started.
  """
  def memory_recycle_counts do
    GenServer.call(__MODULE__, :memory_recycle_counts)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic checks
    check_ref = schedule_lifecycle_check()
    health_ref = schedule_health_check()

    state = %__MODULE__{
      workers: %{},
      check_ref: check_ref,
      health_ref: health_ref,
      memory_recycle_counts: %{},
      lifecycle_task_ref: nil,
      lifecycle_task_pid: nil,
      recycle_task_refs: %{}
    }

    SLog.info(@log_category, "Worker LifecycleManager started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track, pool_name, worker_id, worker_pid, config}, state) do
    lifecycle_config =
      LifecycleConfig.ensure(pool_name, config, worker_module: Snakepit.GRPCWorker)

    ttl = lifecycle_config.worker_ttl_seconds
    max_requests = lifecycle_config.worker_max_requests
    memory_threshold = lifecycle_config.memory_threshold_mb

    monitor_ref = Process.monitor(worker_pid)

    worker_state = %{
      pool: pool_name,
      worker_id: worker_id,
      pid: worker_pid,
      started_at: System.monotonic_time(:second),
      request_count: 0,
      ttl: ttl,
      max_requests: max_requests,
      memory_threshold: memory_threshold,
      config: lifecycle_config,
      monitor_ref: monitor_ref
    }

    new_workers = Map.put(state.workers, worker_id, worker_state)

    SLog.debug(
      @log_category,
      "Tracking worker #{worker_id} (TTL: #{inspect(ttl)}, max_requests: #{inspect(max_requests)})"
    )

    {:noreply, %{state | workers: new_workers}}
  end

  @impl true
  def handle_cast({:untrack, worker_id}, state) do
    {worker_state, new_workers} = pop_worker(state.workers, worker_id)
    maybe_demonitor_worker(worker_state)
    SLog.debug(@log_category, "Untracked worker #{worker_id}")
    {:noreply, %{state | workers: new_workers}}
  end

  @impl true
  def handle_cast({:increment_requests, worker_id}, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        # Worker not tracked (may have been recycled)
        {:noreply, state}

      worker_state ->
        updated_state = %{worker_state | request_count: worker_state.request_count + 1}
        new_workers = Map.put(state.workers, worker_id, updated_state)

        # Check if we hit max requests
        if should_recycle_requests?(updated_state) do
          SLog.info(
            @log_category,
            "Worker #{worker_id} reached max requests (#{updated_state.request_count}), scheduling recycle"
          )

          # Schedule recycle asynchronously
          GenServer.cast(self(), {:recycle_worker, worker_id, :max_requests})
        end

        {:noreply, %{state | workers: new_workers}}
    end
  end

  @impl true
  def handle_cast({:recycle_worker, worker_id, reason}, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        SLog.debug(@log_category, "Worker #{worker_id} already recycled")
        {:noreply, state}

      worker_state ->
        SLog.info(@log_category, "Recycling worker #{worker_id} (reason: #{reason})")

        # Emit telemetry
        emit_recycle_telemetry(worker_state, reason)

        {removed_worker_state, new_workers} = pop_worker(state.workers, worker_id)
        maybe_demonitor_worker(removed_worker_state)
        new_state = %{state | workers: new_workers}

        {:noreply, start_recycle_task(new_state, worker_state)}
    end
  end

  @impl true
  def handle_call({:recycle, pool_name, worker_id}, _from, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        {:reply, {:error, :worker_not_found}, state}

      worker_state ->
        if worker_state.pool == pool_name do
          SLog.info(@log_category, "Manual recycle requested for worker #{worker_id}")

          # Emit telemetry
          emit_recycle_telemetry(worker_state, :manual)

          {removed_worker_state, new_workers} = pop_worker(state.workers, worker_id)
          maybe_demonitor_worker(removed_worker_state)
          new_state = %{state | workers: new_workers}

          {:reply, :ok, start_recycle_task(new_state, worker_state)}
        else
          {:reply, {:error, :pool_mismatch}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      total_workers: map_size(state.workers),
      workers_by_pool:
        state.workers
        |> Enum.group_by(fn {_id, worker} -> worker.pool end)
        |> Map.new(fn {pool, workers} -> {pool, length(workers)} end),
      total_requests:
        state.workers
        |> Enum.map(fn {_id, worker} -> worker.request_count end)
        |> Enum.sum(),
      workers_near_ttl: count_workers_near_ttl(state.workers),
      workers_near_max_requests: count_workers_near_max_requests(state.workers),
      memory_recycles_by_pool: state.memory_recycle_counts
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:memory_recycle_counts, _from, state) do
    {:reply, state.memory_recycle_counts, state}
  end

  @impl true
  def handle_info(:lifecycle_check, %{lifecycle_task_ref: ref} = state) when is_reference(ref) do
    SLog.debug(@log_category, "Lifecycle check tick skipped; previous cycle still in progress")
    {:noreply, state}
  end

  @impl true
  def handle_info(:lifecycle_check, state) do
    now = System.monotonic_time(:second)

    {:ok, task_pid, task_ref} =
      start_nolink_task(fn ->
        recycled_workers = run_lifecycle_checks(state.workers, now)
        {:lifecycle_check_complete, recycled_workers}
      end)

    {:noreply, %{state | lifecycle_task_ref: task_ref, lifecycle_task_pid: task_pid}}
  end

  @impl true
  def handle_info(
        {ref, {:lifecycle_check_complete, recycled_workers}},
        %{lifecycle_task_ref: ref} = state
      ) do
    Process.demonitor(ref, [:flush])

    new_workers =
      Enum.reduce(recycled_workers, state.workers, fn {worker_id, _pool_name, _reason}, workers ->
        {worker_state, workers} = pop_worker(workers, worker_id)
        maybe_demonitor_worker(worker_state)
        workers
      end)

    check_ref = schedule_lifecycle_check()

    {:noreply,
     %{
       state
       | workers: new_workers,
         check_ref: check_ref,
         lifecycle_task_ref: nil,
         lifecycle_task_pid: nil
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{lifecycle_task_ref: ref} = state) do
    if reason == :normal do
      # Result message may still be in flight; wait for `{ref, result}` before clearing task state.
      {:noreply, state}
    else
      SLog.warning(@log_category, "Lifecycle check task exited unexpectedly", reason: reason)
      check_ref = schedule_lifecycle_check()

      {:noreply,
       %{state | check_ref: check_ref, lifecycle_task_ref: nil, lifecycle_task_pid: nil}}
    end
  end

  @impl true
  def handle_info({ref, recycle_result}, state) when is_reference(ref) do
    case Map.fetch(state.recycle_task_refs, ref) do
      {:ok, %{worker_id: worker_id}} ->
        Process.demonitor(ref, [:flush])

        case recycle_result do
          :ok ->
            :ok

          {:error, reason} ->
            SLog.warning(@log_category, "Worker recycle task failed",
              worker_id: worker_id,
              reason: reason
            )

          other ->
            SLog.debug(@log_category, "Worker recycle task completed",
              worker_id: worker_id,
              result: other
            )
        end

        {:noreply, drop_recycle_task_ref(state, ref)}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.recycle_task_refs, ref) do
      {:ok, %{worker_id: worker_id}} ->
        if reason not in [:normal, :shutdown] do
          SLog.warning(@log_category, "Worker recycle task exited unexpectedly",
            worker_id: worker_id,
            reason: reason
          )
        end

        {:noreply, drop_recycle_task_ref(state, ref)}

      :error ->
        handle_worker_down_by_pid(state, pid, reason)
    end
  end

  @impl true
  def handle_info({:memory_recycle_detected, pool_name}, state) do
    new_counts = Map.update(state.memory_recycle_counts, pool_name, 1, &(&1 + 1))
    {:noreply, %{state | memory_recycle_counts: new_counts}}
  end

  @impl true
  def handle_info(:health_check, state) do
    health_check_timeout_ms = Config.lifecycle_worker_action_timeout_ms()

    Enum.each(state.workers, fn {worker_id, worker_state} ->
      start_health_check_task(worker_id, worker_state, health_check_timeout_ms)
    end)

    # Schedule next health check
    health_ref = schedule_health_check()

    {:noreply, %{state | health_ref: health_ref}}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.check_ref)
    cancel_timer(state.health_ref)
    cleanup_tracked_task(state.lifecycle_task_ref, state.lifecycle_task_pid)
    cleanup_recycle_tasks(state.recycle_task_refs)
    :ok
  end

  defp handle_worker_down_by_pid(state, pid, reason) when is_pid(pid) do
    # Find worker by PID
    case Enum.find(state.workers, fn {_id, worker} -> worker.pid == pid end) do
      nil ->
        # Not a tracked worker
        {:noreply, state}

      {worker_id, worker_state} ->
        if Application.get_env(:snakepit, :test_mode, false) do
          SLog.debug(
            @log_category,
            "Worker #{worker_id} (#{inspect(pid)}) died: #{inspect(reason)}"
          )
        else
          SLog.warning(
            @log_category,
            "Worker #{worker_id} (#{inspect(pid)}) died: #{inspect(reason)}"
          )
        end

        # Emit telemetry
        emit_recycle_telemetry(worker_state, :worker_died)

        # Remove from tracking (supervisor will restart automatically)
        {removed_worker_state, new_workers} = pop_worker(state.workers, worker_id)
        maybe_demonitor_worker(removed_worker_state)
        {:noreply, %{state | workers: new_workers}}
    end
  end

  defp handle_worker_down_by_pid(state, _pid, _reason), do: {:noreply, state}

  # Private Functions

  defp schedule_lifecycle_check do
    Process.send_after(self(), :lifecycle_check, Defaults.lifecycle_check_interval())
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, Defaults.lifecycle_health_check_interval())
  end

  defp run_lifecycle_checks(workers, now) do
    max_concurrency = Config.lifecycle_check_max_concurrency()
    worker_timeout = Config.lifecycle_worker_action_timeout_ms()

    lifecycle_check_results_stream(workers, now, worker_timeout, max_concurrency)
    |> Enum.reduce([], fn
      {:ok, {:recycled, worker_id, pool_name, reason}}, worker_ids ->
        [{worker_id, pool_name, reason} | worker_ids]

      {:ok, :keep}, worker_ids ->
        worker_ids

      {:exit, reason}, worker_ids ->
        SLog.warning(@log_category, "Lifecycle check worker task exited", reason: reason)
        worker_ids
    end)
  end

  defp start_recycle_task(state, worker_state) do
    {:ok, task_pid, task_ref} = start_nolink_task(fn -> do_recycle_worker(worker_state) end)
    task_meta = %{worker_id: worker_state.worker_id, task_pid: task_pid}
    recycle_task_refs = Map.put(state.recycle_task_refs, task_ref, task_meta)
    %{state | recycle_task_refs: recycle_task_refs}
  end

  defp drop_recycle_task_ref(state, ref) do
    %{state | recycle_task_refs: Map.delete(state.recycle_task_refs, ref)}
  end

  defp lifecycle_check_results_stream(workers, now, worker_timeout, max_concurrency) do
    try do
      Task.Supervisor.async_stream_nolink(
        Snakepit.TaskSupervisor,
        workers,
        &run_single_lifecycle_check(&1, now),
        timeout: worker_timeout,
        max_concurrency: max_concurrency,
        on_timeout: :kill_task,
        ordered: false
      )
    rescue
      error ->
        SLog.warning(
          @log_category,
          "TaskSupervisor unavailable for lifecycle async stream; using sequential fallback",
          error: error
        )

        sequential_lifecycle_check_results(workers, now)
    catch
      :exit, reason ->
        SLog.warning(
          @log_category,
          "TaskSupervisor exited during lifecycle async stream; using sequential fallback",
          reason: reason
        )

        sequential_lifecycle_check_results(workers, now)
    end
  end

  defp sequential_lifecycle_check_results(workers, now) do
    Enum.map(workers, &run_lifecycle_check_worker_safe(&1, now))
  end

  defp run_lifecycle_check_worker_safe(worker_entry, now) do
    try do
      {:ok, run_single_lifecycle_check(worker_entry, now)}
    rescue
      exception ->
        {:exit, {exception, __STACKTRACE__}}
    catch
      kind, reason ->
        {:exit, {kind, reason}}
    end
  end

  defp run_single_lifecycle_check({worker_id, worker_state}, now) do
    case recycle_decision(worker_state, now) do
      {:recycle, reason, extra_metadata} ->
        log_recycle_reason(worker_id, reason, extra_metadata)
        emit_recycle_telemetry(worker_state, reason, extra_metadata)

        if reason == :memory_threshold do
          send(__MODULE__, {:memory_recycle_detected, worker_state.pool})
        end

        _ = do_recycle_worker(worker_state)
        {:recycled, worker_id, worker_state.pool, reason}

      :keep ->
        :keep
    end
  end

  defp start_nolink_task(fun) when is_function(fun, 0) do
    try do
      task = Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fun)
      {:ok, task.pid, task.ref}
    rescue
      error ->
        SLog.warning(@log_category, "TaskSupervisor unavailable; using monitored fallback task",
          error: error
        )

        start_monitored_fallback_task(fun)
    catch
      :exit, reason ->
        SLog.warning(@log_category, "TaskSupervisor exited; using monitored fallback task",
          reason: reason
        )

        start_monitored_fallback_task(fun)
    end
  end

  defp start_monitored_fallback_task(fun) when is_function(fun, 0) do
    AsyncFallback.start_monitored(fun)
  end

  defp pop_worker(workers, worker_id) do
    Map.pop(workers, worker_id)
  end

  defp cleanup_recycle_tasks(recycle_task_refs) when is_map(recycle_task_refs) do
    Enum.each(recycle_task_refs, fn {ref, task_meta} ->
      cleanup_tracked_task(ref, recycle_task_pid(task_meta))
    end)
  end

  defp cleanup_recycle_tasks(_), do: :ok

  defp cleanup_tracked_task(ref, pid) do
    maybe_demonitor_ref(ref)
    maybe_kill_task_pid(pid)
    :ok
  end

  defp recycle_task_pid(%{task_pid: pid}) when is_pid(pid), do: pid
  defp recycle_task_pid(_), do: nil

  defp maybe_demonitor_ref(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp maybe_demonitor_ref(_), do: :ok

  defp maybe_kill_task_pid(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_kill_task_pid(_), do: :ok

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp maybe_demonitor_worker(%{monitor_ref: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp maybe_demonitor_worker(_), do: :ok

  defp recycle_decision(worker_state, now) do
    cond do
      should_recycle_ttl?(worker_state, now) ->
        {:recycle, :ttl_expired, %{}}

      should_recycle_requests?(worker_state) ->
        {:recycle, :max_requests, %{}}

      true ->
        case memory_recycle_decision(worker_state) do
          nil -> :keep
          extra -> {:recycle, :memory_threshold, extra}
        end
    end
  end

  defp should_recycle_ttl?(worker_state, now) do
    case worker_state.ttl do
      :infinity -> false
      ttl_seconds -> now - worker_state.started_at >= ttl_seconds
    end
  end

  defp should_recycle_requests?(worker_state) do
    case worker_state.max_requests do
      :infinity -> false
      max -> worker_state.request_count >= max
    end
  end

  defp memory_recycle_decision(worker_state) do
    case worker_state.memory_threshold do
      nil ->
        nil

      threshold_mb ->
        case get_worker_memory_mb(worker_state.pid) do
          {:ok, memory_mb} when memory_mb >= threshold_mb ->
            %{memory_mb: memory_mb, memory_threshold_mb: threshold_mb}

          {:ok, _memory_mb} ->
            nil

          {:error, reason} ->
            SLog.warning(
              @log_category,
              "Memory probe for #{worker_state.worker_id} failed: #{inspect(reason)} (threshold #{threshold_mb} MB)"
            )

            nil
        end
    end
  end

  defp log_recycle_reason(worker_id, :ttl_expired, _extra) do
    SLog.info(@log_category, "Worker #{worker_id} TTL expired, recycling...")
  end

  defp log_recycle_reason(worker_id, :max_requests, _extra) do
    SLog.info(@log_category, "Worker #{worker_id} reached max requests, recycling...")
  end

  defp log_recycle_reason(worker_id, :memory_threshold, %{
         memory_mb: memory_mb,
         memory_threshold_mb: threshold_mb
       }) do
    SLog.info(
      @log_category,
      "Worker #{worker_id} exceeded memory threshold (#{memory_mb} MB >= #{threshold_mb} MB), recycling..."
    )
  end

  defp log_recycle_reason(worker_id, other_reason, _extra) do
    SLog.info(@log_category, "Worker #{worker_id} recycling due to #{inspect(other_reason)}")
  end

  defp do_recycle_worker(worker_state) do
    pool_name = worker_state.pool
    worker_id = worker_state.worker_id

    # Stop the old worker
    SLog.debug(@log_category, "Stopping worker #{worker_id} for recycling...")

    # Get the profile module for this worker
    profile_module = lifecycle_profile_module(worker_state.config)

    # Stop via profile
    case profile_module.stop_worker(worker_state.pid) do
      :ok ->
        SLog.debug(@log_category, "Worker #{worker_id} stopped successfully")

        # Start a replacement
        case start_replacement_worker(pool_name, worker_state.config) do
          {:ok, new_pid} ->
            SLog.info(
              @log_category,
              "Worker #{worker_id} recycled successfully (new PID: #{inspect(new_pid)})"
            )

            :ok

          {:error, reason} ->
            SLog.error(
              @log_category,
              "Failed to start replacement for #{worker_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      error ->
        SLog.error(@log_category, "Failed to stop worker #{worker_id}: #{inspect(error)}")
        error
    end
  end

  defp start_replacement_worker(pool_name, %LifecycleConfig{} = config) do
    # Generate new worker ID
    worker_id = "pool_worker_#{:erlang.unique_integer([:positive])}"

    profile_module = config.profile_module

    # Build config for new worker
    worker_config = LifecycleConfig.to_worker_config(config, worker_id)

    # Start via profile
    case profile_module.start_worker(worker_config) do
      {:ok, pid} ->
        # Track the new worker
        track_worker(pool_name, worker_id, pid, config)
        {:ok, pid}

      error ->
        error
    end
  end

  defp start_replacement_worker(pool_name, config) when is_map(config) do
    lifecycle_config = LifecycleConfig.ensure(pool_name, config)
    start_replacement_worker(pool_name, lifecycle_config)
  end

  defp check_worker_health(worker_id, worker_state) do
    profile_module = lifecycle_profile_module(worker_state.config)

    case profile_module.health_check(worker_state.pid) do
      :ok ->
        SLog.debug(@log_category, "Worker #{worker_id} health check passed")

      {:error, reason} ->
        SLog.warning(@log_category, "Worker #{worker_id} health check failed: #{inspect(reason)}")

        # Emit telemetry
        :telemetry.execute(
          [:snakepit, :worker, :health_check_failed],
          %{count: 1},
          %{
            worker_id: worker_id,
            pool: worker_state.pool,
            reason: reason
          }
        )
    end
  end

  defp start_health_check_task(worker_id, worker_state, timeout_ms) do
    runner = fn -> run_health_check_with_timeout(worker_id, worker_state, timeout_ms) end

    try do
      _ = Task.Supervisor.start_child(Snakepit.TaskSupervisor, runner)
      :ok
    rescue
      error ->
        SLog.warning(
          @log_category,
          "TaskSupervisor unavailable for health check task; using monitored fallback",
          error: error
        )

        _ = AsyncFallback.start_monitored_fire_and_forget(runner)
        :ok
    catch
      :exit, reason ->
        SLog.warning(
          @log_category,
          "TaskSupervisor exited during health check task start; using monitored fallback",
          reason: reason
        )

        _ = AsyncFallback.start_monitored_fire_and_forget(runner)
        :ok
    end
  end

  defp run_health_check_with_timeout(worker_id, worker_state, timeout_ms) do
    case TimeoutRunner.run(fn -> check_worker_health(worker_id, worker_state) end, timeout_ms) do
      {:ok, _result} ->
        :ok

      :timeout ->
        SLog.warning(
          @log_category,
          "Worker #{worker_id} health check timed out",
          timeout_ms: timeout_ms
        )

      {:error, reason} ->
        SLog.warning(
          @log_category,
          "Worker #{worker_id} health check task crashed",
          reason: reason
        )
    end
  end

  defp get_worker_memory_mb(worker_pid) do
    # Try to get memory usage from worker
    # This requires worker to expose memory info
    case GenServer.call(worker_pid, :get_memory_usage, 1000) do
      {:ok, memory_bytes} ->
        {:ok, div(memory_bytes, 1024 * 1024)}

      _ ->
        {:error, :not_available}
    end
  catch
    :exit, _ -> {:error, :worker_not_responding}
  end

  defp count_workers_near_ttl(workers) do
    now = System.monotonic_time(:second)

    Enum.count(workers, fn {_id, worker} ->
      case worker.ttl do
        :infinity ->
          false

        ttl_seconds ->
          age = now - worker.started_at
          # Within 10% of TTL
          age >= ttl_seconds * 0.9
      end
    end)
  end

  defp count_workers_near_max_requests(workers) do
    Enum.count(workers, fn {_id, worker} ->
      case worker.max_requests do
        :infinity ->
          false

        max ->
          # Within 10% of max
          worker.request_count >= max * 0.9
      end
    end)
  end

  defp emit_recycle_telemetry(worker_state, reason, extra_metadata \\ %{}) do
    measurements =
      case Map.get(extra_metadata, :memory_mb) do
        nil -> %{count: 1}
        memory_mb -> %{count: 1, memory_mb: memory_mb}
      end

    metadata =
      %{
        worker_id: worker_state.worker_id,
        pool: worker_state.pool,
        reason: reason,
        uptime_seconds: System.monotonic_time(:second) - worker_state.started_at,
        request_count: worker_state.request_count
      }
      |> maybe_put_metadata(:memory_threshold_mb, Map.get(extra_metadata, :memory_threshold_mb))
      |> maybe_put_metadata(:memory_mb, Map.get(extra_metadata, :memory_mb))

    :telemetry.execute([:snakepit, :worker, :recycled], measurements, metadata)
  end

  defp lifecycle_profile_module(%LifecycleConfig{profile_module: module}), do: module

  defp lifecycle_profile_module(config) when is_map(config) do
    case Map.get(config, :worker_profile, :process) do
      :process -> Snakepit.WorkerProfile.Process
      :thread -> Snakepit.WorkerProfile.Thread
      module when is_atom(module) -> module
    end
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)
end
