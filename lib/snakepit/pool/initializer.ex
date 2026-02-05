defmodule Snakepit.Pool.Initializer do
  @moduledoc false

  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.State
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Shutdown

  @log_category :pool

  def run(state) do
    total_workers = Enum.reduce(state.pools, 0, fn {_name, pool}, acc -> acc + pool.size end)

    emit_init_started_telemetry(total_workers)

    SLog.info(
      @log_category,
      "🚀 Starting concurrent initialization of #{total_workers} workers across #{map_size(state.pools)} pool(s)..."
    )

    start_time = System.monotonic_time(:millisecond)

    # DIAGNOSTIC: Capture baseline system resource usage
    baseline_resources = capture_resource_metrics()
    SLog.info(@log_category, "📊 Baseline resources: #{inspect(baseline_resources)}")

    # Run blocking initialization in a supervised task so Pool callbacks stay responsive
    # while still providing explicit task refs and crash attribution.
    pools_data = state.pools
    # CRITICAL: Capture the Pool GenServer's name BEFORE spawning, so workers
    # get the correct pool reference (not the ephemeral init process's pid)
    pool_genserver_name = get_pool_genserver_name()

    task =
      Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
        updated_pools =
          do_pool_initialization(pools_data, baseline_resources, pool_genserver_name)

        {:pool_init_complete, updated_pools}
      end)

    # Return immediately - GenServer is now responsive to shutdown signals
    {:noreply,
     %{
       state
       | initializing: true,
         init_start_time: start_time,
         init_task_ref: task.ref,
         init_task_pid: task.pid,
         init_resource_baseline: baseline_resources
     }}
  end

  def capture_resource_metrics do
    %{
      beam_processes: length(:erlang.processes()),
      beam_ports: length(:erlang.ports()),
      memory_total_mb: div(:erlang.memory(:total), 1_024 * 1_024),
      memory_processes_mb: div(:erlang.memory(:processes), 1_024 * 1_024),
      ets_tables: length(:ets.all()),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  def calculate_resource_delta(baseline, peak) do
    %{
      processes_delta: peak.beam_processes - baseline.beam_processes,
      ports_delta: peak.beam_ports - baseline.beam_ports,
      memory_delta_mb: peak.memory_total_mb - baseline.memory_total_mb,
      memory_processes_delta_mb: peak.memory_processes_mb - baseline.memory_processes_mb,
      ets_tables_delta: peak.ets_tables - baseline.ets_tables,
      time_elapsed_ms: peak.timestamp - baseline.timestamp
    }
  end

  defp emit_init_started_telemetry(total_workers) do
    :telemetry.execute(
      [:snakepit, :pool, :init_started],
      %{total_workers: total_workers, count: 1},
      %{}
    )
  end

  # Helper to perform blocking pool initialization in a separate process
  # pool_genserver_name is the registered name of the Pool GenServer (captured before spawn)
  defp do_pool_initialization(pools_data, _baseline_resources, pool_genserver_name) do
    ensure_grpc_listener_ready!()

    Enum.map(pools_data, fn {pool_name, pool_state} ->
      SLog.info(
        @log_category,
        "Initializing pool #{pool_name} with #{pool_state.size} workers..."
      )

      # Start workers for this pool (may include blocking batch delays)
      workers =
        start_workers_concurrently(
          pool_name,
          pool_state.size,
          pool_state.startup_timeout,
          pool_state.worker_module,
          pool_state.adapter_module,
          pool_state.pool_config,
          pool_genserver_name
        )

      SLog.info(
        @log_category,
        "✅ Pool #{pool_name}: Initialized #{length(workers)}/#{pool_state.size} workers"
      )

      # Update pool state with workers
      updated_pool_state =
        if Enum.empty?(workers) do
          # Pool failed to start any workers
          SLog.error(@log_category, "❌ Pool #{pool_name} failed to start any workers!")
          %{pool_state | init_failed: pool_state.size > 0}
        else
          worker_capacities = State.build_worker_capacities(pool_state, workers)

          %{
            pool_state
            | workers: workers,
              available: MapSet.new(),
              ready_workers: MapSet.new(),
              worker_capacities: worker_capacities,
              worker_loads: %{},
              initialized: false,
              init_failed: false
          }
        end

      {pool_name, updated_pool_state}
    end)
    |> Enum.into(%{})
  end

  defp ensure_grpc_listener_ready! do
    case Snakepit.GRPC.Listener.await_ready() do
      {:ok, _info} ->
        :ok

      {:error, :timeout} ->
        SLog.error(@log_category, "gRPC listener failed to publish port within timeout")
        exit({:grpc_listener_unavailable, :timeout})
    end
  end

  defp start_workers_concurrently(
         pool_name,
         count,
         startup_timeout,
         worker_module,
         adapter_module,
         pool_config,
         pool_genserver_name
       ) do
    actual_count = enforce_max_workers(count, pool_config)
    log_worker_startup_info(actual_count, worker_module)

    # NOTE: pool_genserver_name is now passed in from the caller
    # (captured before spawning the init process)
    batch_config = get_batch_config(pool_config)

    start_worker_batches(
      pool_name,
      actual_count,
      startup_timeout,
      worker_module,
      adapter_module,
      pool_config,
      pool_genserver_name,
      batch_config
    )
  end

  defp enforce_max_workers(count, pool_config) do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    max_workers =
      Map.get(pool_config, :max_workers) ||
        Map.get(legacy_pool_config, :max_workers, Defaults.pool_max_workers())

    actual_count = min(count, max_workers)

    if actual_count < count do
      SLog.warning(
        @log_category,
        "⚠️  Requested #{count} workers but limiting to #{actual_count} (max_workers=#{max_workers})"
      )

      SLog.warning(
        @log_category,
        "⚠️  To increase this limit, set :pool_config.max_workers in config/config.exs"
      )
    end

    actual_count
  end

  defp log_worker_startup_info(actual_count, worker_module) do
    SLog.info(@log_category, "🚀 Starting concurrent initialization of #{actual_count} workers...")
    SLog.info(@log_category, "📦 Using worker type: #{inspect(worker_module)}")
  end

  defp get_pool_genserver_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} -> name
      nil -> self()
    end
  end

  defp get_batch_config(pool_config) do
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    batch_size =
      Map.get(pool_config, :startup_batch_size) ||
        Map.get(legacy_pool_config, :startup_batch_size, Defaults.pool_startup_batch_size())

    batch_delay =
      Map.get(pool_config, :startup_batch_delay_ms) ||
        Map.get(
          legacy_pool_config,
          :startup_batch_delay_ms,
          Defaults.pool_startup_batch_delay_ms()
        )

    %{size: batch_size, delay: batch_delay}
  end

  defp start_worker_batches(
         pool_name,
         actual_count,
         startup_timeout,
         worker_module,
         adapter_module,
         pool_config,
         pool_genserver_name,
         batch_config
       ) do
    worker_ctx = %{
      pool_name: pool_name,
      actual_count: actual_count,
      startup_timeout: startup_timeout,
      worker_module: worker_module,
      adapter_module: adapter_module,
      pool_config: pool_config,
      pool_genserver_name: pool_genserver_name,
      batch_config: batch_config
    }

    1..actual_count
    |> Enum.chunk_every(batch_config.size)
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, batch_num} ->
      start_single_batch(worker_ctx, batch, batch_num)
    end)
  end

  defp start_single_batch(worker_ctx, batch, batch_num) do
    # CRITICAL: Check if WorkerSupervisor is still alive before starting a batch
    # Short-circuit if app is shutting down to prevent cascading errors
    if supervisor_alive?() do
      %{actual_count: actual_count, startup_timeout: startup_timeout, batch_config: batch_config} =
        worker_ctx

      batch_start = batch_num * batch_config.size + 1
      batch_end = min(batch_start + length(batch) - 1, actual_count)

      SLog.info(
        @log_category,
        "Starting batch #{batch_num + 1}: workers #{batch_start}-#{batch_end}"
      )

      workers =
        batch
        |> Task.async_stream(
          fn i -> start_worker_in_batch(worker_ctx, i) end,
          timeout: startup_timeout,
          max_concurrency: batch_config.size,
          on_timeout: :kill_task
        )
        |> Enum.map(&handle_worker_start_result/1)
        |> Enum.filter(&(&1 != nil))

      maybe_delay_between_batches(batch_num, actual_count, batch_config)
      workers
    else
      SLog.warning(
        @log_category,
        "Skipping batch #{batch_num + 1}: WorkerSupervisor terminated during startup"
      )

      []
    end
  end

  defp start_worker_in_batch(worker_ctx, i) do
    # CRITICAL: Check if WorkerSupervisor is still alive before attempting to start
    # This prevents crashes when app is shutting down during batch initialization
    if supervisor_alive?() do
      %{
        pool_name: pool_name,
        actual_count: actual_count,
        worker_module: worker_module,
        adapter_module: adapter_module,
        pool_config: pool_config,
        pool_genserver_name: pool_genserver_name
      } = worker_ctx

      worker_id = "#{pool_name}_worker_#{i}_#{:erlang.unique_integer([:positive])}"

      result =
        if Map.has_key?(pool_config, :worker_profile) do
          start_worker_with_profile(
            worker_id,
            pool_name,
            worker_module,
            adapter_module,
            pool_config,
            pool_genserver_name
          )
        else
          start_worker_legacy(
            worker_id,
            pool_name,
            worker_module,
            adapter_module,
            pool_genserver_name
          )
        end

      handle_worker_start_result_with_log(result, worker_id, i, actual_count)
    else
      {:error, :supervisor_terminated}
    end
  end

  # Check if the WorkerSupervisor is alive - prevents crashes during shutdown
  defp supervisor_alive? do
    not Shutdown.in_progress?() and
      case Process.whereis(Snakepit.Pool.WorkerSupervisor) do
        nil -> false
        pid -> Process.alive?(pid)
      end
  end

  defp start_worker_with_profile(
         worker_id,
         pool_name,
         worker_module,
         adapter_module,
         pool_config,
         pool_genserver_name
       ) do
    safe_start_worker(fn ->
      profile_module = Config.get_profile_module(pool_config)

      worker_config =
        pool_config
        |> Map.put(:worker_id, worker_id)
        |> Map.put(:worker_module, worker_module)
        |> Map.put(:adapter_module, adapter_module)
        |> Map.put(:pool_name, pool_genserver_name)
        |> Map.put(:pool_identifier, pool_name)

      profile_module.start_worker(worker_config)
    end)
  end

  defp start_worker_legacy(
         worker_id,
         pool_name,
         worker_module,
         adapter_module,
         pool_genserver_name
       ) do
    safe_start_worker(fn ->
      WorkerSupervisor.start_worker(
        worker_id,
        worker_module,
        adapter_module,
        pool_genserver_name,
        %{pool_identifier: pool_name}
      )
    end)
  end

  defp handle_worker_start_result_with_log(result, worker_id, i, actual_count) do
    case result do
      {:ok, _pid} ->
        SLog.info(@log_category, "✅ Worker #{i}/#{actual_count} ready: #{worker_id}")
        worker_id

      {:error, reason} ->
        SLog.error(@log_category, "❌ Worker #{i}/#{actual_count} failed: #{inspect(reason)}")
        nil
    end
  end

  defp handle_worker_start_result({:ok, worker_id}), do: worker_id

  defp handle_worker_start_result({:exit, reason}) do
    SLog.error(@log_category, "Worker startup task failed: #{inspect(reason)}")
    nil
  end

  defp safe_start_worker(start_fun) when is_function(start_fun, 0) do
    case start_fun.() do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_start_result, other}}
    end
  rescue
    exception ->
      {:error, {:worker_start_exception, exception}}
  catch
    :exit, reason ->
      {:error, {:worker_start_exit, reason}}

    kind, reason ->
      {:error, {:worker_start_catch, {kind, reason}}}
  end

  defp maybe_delay_between_batches(batch_num, actual_count, batch_config) do
    unless batch_num == div(actual_count - 1, batch_config.size) do
      wait_for_batch_delay(batch_config.delay)
    end
  end

  defp wait_for_batch_delay(delay_ms) when delay_ms <= 0, do: :ok

  defp wait_for_batch_delay(delay_ms) do
    ref = make_ref()
    Process.send_after(self(), {:startup_batch_delay, ref}, delay_ms)

    receive do
      {:startup_batch_delay, ^ref} -> :ok
    end
  end
end
