defmodule Snakepit.Worker.LifecycleManager do
  @moduledoc """
  Worker lifecycle manager for automatic recycling and health monitoring.

  Manages worker lifecycle events:
  - **TTL-based recycling**: Recycle workers after configured time
  - **Request-count recycling**: Recycle after N requests
  - **Memory monitoring**: Recycle if memory exceeds threshold (optional)
  - **Health checks**: Monitor worker health and restart if needed

  ## Why Worker Recycling?

  Long-running Python processes can accumulate memory due to:
  - Memory fragmentation
  - Cache growth
  - Subtle memory leaks in C libraries
  - ML model weight accumulation

  Automatic recycling prevents these issues from impacting production.

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
  require Logger
  alias Snakepit.Logger, as: SLog

  # Check every 60 seconds
  @check_interval 60_000
  # Health check every 5 minutes
  @health_check_interval 300_000

  defstruct [
    :workers,
    :check_ref,
    :health_ref
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

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic checks
    check_ref = schedule_lifecycle_check()
    health_ref = schedule_health_check()

    state = %__MODULE__{
      workers: %{},
      check_ref: check_ref,
      health_ref: health_ref
    }

    SLog.info("Worker LifecycleManager started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track, pool_name, worker_id, worker_pid, config}, state) do
    # Extract lifecycle configuration
    ttl = parse_ttl(config[:worker_ttl] || :infinity)
    max_requests = config[:worker_max_requests] || :infinity
    memory_threshold = config[:memory_threshold_mb]

    worker_state = %{
      pool: pool_name,
      worker_id: worker_id,
      pid: worker_pid,
      started_at: System.monotonic_time(:second),
      request_count: 0,
      ttl: ttl,
      max_requests: max_requests,
      memory_threshold: memory_threshold,
      config: config
    }

    # Monitor the worker process
    Process.monitor(worker_pid)

    new_workers = Map.put(state.workers, worker_id, worker_state)

    SLog.debug(
      "Tracking worker #{worker_id} (TTL: #{inspect(ttl)}, max_requests: #{inspect(max_requests)})"
    )

    {:noreply, %{state | workers: new_workers}}
  end

  @impl true
  def handle_cast({:untrack, worker_id}, state) do
    new_workers = Map.delete(state.workers, worker_id)
    SLog.debug("Untracked worker #{worker_id}")
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
        SLog.debug("Worker #{worker_id} already recycled")
        {:noreply, state}

      worker_state ->
        SLog.info("Recycling worker #{worker_id} (reason: #{reason})")

        # Emit telemetry
        emit_recycle_telemetry(worker_state, reason)

        # Perform recycling
        do_recycle_worker(worker_state)

        # Remove from tracking
        new_workers = Map.delete(state.workers, worker_id)
        {:noreply, %{state | workers: new_workers}}
    end
  end

  @impl true
  def handle_call({:recycle, pool_name, worker_id}, _from, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        {:reply, {:error, :worker_not_found}, state}

      worker_state ->
        if worker_state.pool == pool_name do
          SLog.info("Manual recycle requested for worker #{worker_id}")

          # Emit telemetry
          emit_recycle_telemetry(worker_state, :manual)

          # Perform recycling
          do_recycle_worker(worker_state)

          # Remove from tracking
          new_workers = Map.delete(state.workers, worker_id)
          {:reply, :ok, %{state | workers: new_workers}}
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
      workers_near_max_requests: count_workers_near_max_requests(state.workers)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:lifecycle_check, state) do
    now = System.monotonic_time(:second)

    # Check all workers for recycling conditions
    recycled_workers =
      Enum.reduce(state.workers, [], fn {worker_id, worker_state}, acc ->
        cond do
          should_recycle_ttl?(worker_state, now) ->
            SLog.info("Worker #{worker_id} TTL expired, recycling...")
            emit_recycle_telemetry(worker_state, :ttl_expired)
            do_recycle_worker(worker_state)
            [worker_id | acc]

          should_recycle_requests?(worker_state) ->
            SLog.info("Worker #{worker_id} reached max requests, recycling...")
            emit_recycle_telemetry(worker_state, :max_requests)
            do_recycle_worker(worker_state)
            [worker_id | acc]

          should_recycle_memory?(worker_state) ->
            SLog.info("Worker #{worker_id} exceeded memory threshold, recycling...")
            emit_recycle_telemetry(worker_state, :memory_threshold)
            do_recycle_worker(worker_state)
            [worker_id | acc]

          true ->
            acc
        end
      end)

    # Remove recycled workers from tracking
    new_workers =
      Enum.reduce(recycled_workers, state.workers, fn worker_id, workers ->
        Map.delete(workers, worker_id)
      end)

    # Schedule next check
    check_ref = schedule_lifecycle_check()

    {:noreply, %{state | workers: new_workers, check_ref: check_ref}}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Perform health checks on all workers
    Enum.each(state.workers, fn {worker_id, worker_state} ->
      check_worker_health(worker_id, worker_state)
    end)

    # Schedule next health check
    health_ref = schedule_health_check()

    {:noreply, %{state | health_ref: health_ref}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find worker by PID
    case Enum.find(state.workers, fn {_id, worker} -> worker.pid == pid end) do
      nil ->
        # Not a tracked worker
        {:noreply, state}

      {worker_id, worker_state} ->
        SLog.warning("Worker #{worker_id} (#{inspect(pid)}) died: #{inspect(reason)}")

        # Emit telemetry
        emit_recycle_telemetry(worker_state, :worker_died)

        # Remove from tracking (supervisor will restart automatically)
        new_workers = Map.delete(state.workers, worker_id)
        {:noreply, %{state | workers: new_workers}}
    end
  end

  # Private Functions

  defp schedule_lifecycle_check do
    Process.send_after(self(), :lifecycle_check, @check_interval)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
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

  defp should_recycle_memory?(worker_state) do
    case worker_state.memory_threshold do
      nil ->
        false

      threshold_mb ->
        # Get current memory usage (if available)
        case get_worker_memory_mb(worker_state.pid) do
          {:ok, memory_mb} -> memory_mb >= threshold_mb
          _ -> false
        end
    end
  end

  defp do_recycle_worker(worker_state) do
    pool_name = worker_state.pool
    worker_id = worker_state.worker_id

    # Stop the old worker
    SLog.debug("Stopping worker #{worker_id} for recycling...")

    # Get the profile module for this worker
    profile_module = get_profile_module(worker_state.config)

    # Stop via profile
    case profile_module.stop_worker(worker_state.pid) do
      :ok ->
        SLog.debug("Worker #{worker_id} stopped successfully")

        # Start a replacement
        case start_replacement_worker(pool_name, worker_state.config) do
          {:ok, new_pid} ->
            SLog.info("Worker #{worker_id} recycled successfully (new PID: #{inspect(new_pid)})")

            :ok

          {:error, reason} ->
            SLog.error("Failed to start replacement for #{worker_id}: #{inspect(reason)}")
            {:error, reason}
        end

      error ->
        SLog.error("Failed to stop worker #{worker_id}: #{inspect(error)}")
        error
    end
  end

  defp start_replacement_worker(pool_name, config) do
    # Generate new worker ID
    worker_id = "pool_worker_#{:erlang.unique_integer([:positive])}"

    # Get profile module
    profile_module = get_profile_module(config)

    # Build config for new worker
    worker_config =
      config
      |> Map.put(:worker_id, worker_id)
      |> Map.put(:pool_name, pool_name)

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

  defp get_profile_module(config) do
    case Map.get(config, :worker_profile, :process) do
      :process -> Snakepit.WorkerProfile.Process
      :thread -> Snakepit.WorkerProfile.Thread
    end
  end

  defp check_worker_health(worker_id, worker_state) do
    profile_module = get_profile_module(worker_state.config)

    case profile_module.health_check(worker_state.pid) do
      :ok ->
        SLog.debug("Worker #{worker_id} health check passed")

      {:error, reason} ->
        SLog.warning("Worker #{worker_id} health check failed: #{inspect(reason)}")

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

  defp get_worker_memory_mb(worker_pid) do
    # Try to get memory usage from worker
    # This requires worker to expose memory info
    try do
      case GenServer.call(worker_pid, :get_memory_usage, 1000) do
        {:ok, memory_bytes} ->
          {:ok, div(memory_bytes, 1024 * 1024)}

        _ ->
          {:error, :not_available}
      end
    catch
      :exit, _ -> {:error, :worker_not_responding}
    end
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

  defp emit_recycle_telemetry(worker_state, reason) do
    :telemetry.execute(
      [:snakepit, :worker, :recycled],
      %{count: 1},
      %{
        worker_id: worker_state.worker_id,
        pool: worker_state.pool,
        reason: reason,
        uptime_seconds: System.monotonic_time(:second) - worker_state.started_at,
        request_count: worker_state.request_count
      }
    )
  end

  defp parse_ttl(:infinity), do: :infinity
  defp parse_ttl({value, :seconds}), do: value
  defp parse_ttl({value, :minutes}), do: value * 60
  defp parse_ttl({value, :hours}), do: value * 3600
  defp parse_ttl({value, :days}), do: value * 86400
  defp parse_ttl(value) when is_integer(value), do: value
end
