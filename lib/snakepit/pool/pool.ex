defmodule Snakepit.Pool do
  @moduledoc """
  Pool manager for external workers with concurrent initialization.

  Features:
  - Concurrent worker startup (all workers start in parallel)
  - Simple queue-based request distribution
  - Non-blocking async execution
  - Automatic request queueing when workers are busy
  - Adapter-based support for any external process
  """

  use GenServer
  require Logger
  alias Snakepit.Logger, as: SLog

  @default_size System.schedulers_online() * 2
  @default_startup_timeout 10_000
  @default_queue_timeout 5_000
  @default_max_queue_size 1000

  # Per-pool state structure
  defmodule PoolState do
    @moduledoc false
    defstruct [
      :name,
      :size,
      :workers,
      :available,
      :busy,
      :request_queue,
      :cancelled_requests,
      :stats,
      :initialized,
      :startup_timeout,
      :queue_timeout,
      :max_queue_size,
      :worker_module,
      :adapter_module,
      :pool_config,
      initialization_waiters: []
    ]
  end

  # Top-level state structure
  defstruct [
    :pools,
    # Map of pool_name => PoolState
    :affinity_cache,
    # Shared across all pools
    :default_pool
    # Default pool name for backward compatibility
  ]

  # Client API

  @doc """
  Starts the pool manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Executes a command on any available worker.
  """
  def execute(command, args, opts \\ []) do
    pool = opts[:pool] || __MODULE__
    timeout = opts[:timeout] || 60_000

    GenServer.call(pool, {:execute, command, args, opts}, timeout)
  end

  @doc """
  Execute a streaming command with callback.
  """
  def execute_stream(command, args, callback_fn, opts \\ []) do
    pool = opts[:pool] || __MODULE__
    timeout = opts[:timeout] || 300_000
    SLog.info("[Pool] execute_stream called for command: #{command}, args: #{inspect(args)}")

    case checkout_worker_for_stream(pool, opts) do
      {:ok, worker_id} ->
        SLog.info("[Pool] Checked out worker: #{worker_id}")

        # CRITICAL FIX: Use try/after to guarantee worker checkin even if execution crashes
        try do
          execute_on_worker_stream(worker_id, command, args, callback_fn, timeout)
        after
          # This block ALWAYS executes, preventing worker leaks on crashes
          SLog.info("[Pool] Checking in worker #{worker_id} after stream execution")
          checkin_worker(pool, worker_id)
        end

      {:error, reason} ->
        SLog.error("[Pool] Failed to checkout worker: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp checkout_worker_for_stream(pool, opts) do
    timeout = opts[:checkout_timeout] || 5_000
    GenServer.call(pool, {:checkout_worker, opts[:session_id]}, timeout)
  end

  defp checkin_worker(pool, worker_id) do
    GenServer.cast(pool, {:checkin_worker, worker_id})
  end

  defp execute_on_worker_stream(worker_id, command, args, callback_fn, timeout) do
    worker_module = get_worker_module(worker_id)
    SLog.info("[Pool] execute_on_worker_stream - worker_module: #{inspect(worker_module)}")

    if function_exported?(worker_module, :execute_stream, 5) do
      SLog.info("[Pool] Calling #{worker_module}.execute_stream with timeout: #{timeout}")
      result = worker_module.execute_stream(worker_id, command, args, callback_fn, timeout)
      SLog.info("[Pool] execute_stream returned: #{inspect(result)}")
      result
    else
      SLog.error("[Pool] Worker module #{worker_module} does not export execute_stream/5")
      {:error, :streaming_not_supported_by_worker}
    end
  end

  @doc """
  Gets pool statistics.
  """
  def get_stats(pool \\ __MODULE__) do
    GenServer.call(pool, :get_stats)
  end

  @doc """
  Lists all worker IDs in the pool.

  Can be called with pool process or pool name:
  - `list_workers()` - all workers from all pools
  - `list_workers(Snakepit.Pool)` - all workers from all pools
  - `list_workers(Snakepit.Pool, :pool_name)` - workers from specific pool
  """
  def list_workers(pool \\ __MODULE__)

  def list_workers(pool) when is_pid(pool) or is_atom(pool) do
    # Call with just pool process (backward compat)
    GenServer.call(pool, :list_workers)
  end

  def list_workers(pool, pool_name) when is_atom(pool_name) do
    # Call with pool process and pool name
    GenServer.call(pool, {:list_workers, pool_name})
  end

  @doc """
  Waits for the pool to be fully initialized.

  Returns `:ok` when all workers are ready, or `{:error, :timeout}` if
  the pool doesn't initialize within the given timeout.
  """
  @spec await_ready(atom() | pid(), timeout()) :: :ok | {:error, :timeout}
  def await_ready(pool \\ __MODULE__, timeout \\ 15_000) do
    GenServer.call(pool, :await_ready, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # CRITICAL: Trap exits to ensure terminate/2 is called
    Process.flag(:trap_exit, true)

    # v0.6.0: Get ALL pool configurations from Config system
    pool_configs =
      case Snakepit.Config.get_pool_configs() do
        {:ok, configs} when is_list(configs) and length(configs) > 0 ->
          SLog.info("Initializing #{length(configs)} pool(s)")
          configs

        {:ok, []} ->
          SLog.warning("No pool configs found, using legacy defaults")
          [%{name: :default}]

        {:error, reason} ->
          SLog.warning("Config system error (#{inspect(reason)}), using legacy defaults")
          [%{name: :default}]
      end

    # PERFORMANCE FIX: Create ETS cache for session affinity to eliminate
    # GenServer bottleneck on SessionStore. This provides ~100x faster lookups.
    # Shared across ALL pools
    affinity_cache =
      :ets.new(:worker_affinity_cache, [
        :set,
        :public,
        {:read_concurrency, true}
      ])

    # Create initial pool states (not yet initialized with workers)
    pools =
      Enum.reduce(pool_configs, %{}, fn pool_config, acc ->
        pool_name = Map.get(pool_config, :name, :default)

        # Extract pool settings with backward-compatible fallbacks
        size = opts[:size] || Map.get(pool_config, :pool_size, @default_size)

        startup_timeout =
          Application.get_env(:snakepit, :pool_startup_timeout, @default_startup_timeout)

        queue_timeout =
          Application.get_env(:snakepit, :pool_queue_timeout, @default_queue_timeout)

        max_queue_size =
          Application.get_env(:snakepit, :pool_max_queue_size, @default_max_queue_size)

        worker_module = opts[:worker_module] || Snakepit.GRPCWorker

        adapter_module =
          opts[:adapter_module] ||
            Map.get(pool_config, :adapter_module) ||
            Application.get_env(:snakepit, :adapter_module)

        pool_state = %PoolState{
          name: pool_name,
          size: size,
          workers: [],
          available: MapSet.new(),
          busy: %{},
          request_queue: :queue.new(),
          cancelled_requests: MapSet.new(),
          stats: %{
            requests: 0,
            queued: 0,
            errors: 0,
            queue_timeouts: 0,
            pool_saturated: 0
          },
          initialized: false,
          startup_timeout: startup_timeout,
          queue_timeout: queue_timeout,
          max_queue_size: max_queue_size,
          worker_module: worker_module,
          adapter_module: adapter_module,
          pool_config: pool_config
        }

        Map.put(acc, pool_name, pool_state)
      end)

    # Determine default pool (first pool or :default)
    default_pool =
      case pool_configs do
        [first | _] -> Map.get(first, :name, :default)
        [] -> :default
      end

    state = %__MODULE__{
      pools: pools,
      affinity_cache: affinity_cache,
      default_pool: default_pool
    }

    # Start concurrent worker initialization for ALL pools
    {:ok, state, {:continue, :initialize_workers}}
  end

  @impl true
  def handle_continue(:initialize_workers, state) do
    total_workers = Enum.reduce(state.pools, 0, fn {_name, pool}, acc -> acc + pool.size end)

    SLog.info(
      "🚀 Starting concurrent initialization of #{total_workers} workers across #{map_size(state.pools)} pool(s)..."
    )

    start_time = System.monotonic_time(:millisecond)

    # DIAGNOSTIC: Capture baseline system resource usage
    baseline_resources = capture_resource_metrics()
    SLog.info("📊 Baseline resources: #{inspect(baseline_resources)}")

    # Initialize ALL pools concurrently
    updated_pools =
      Enum.map(state.pools, fn {pool_name, pool_state} ->
        SLog.info("Initializing pool #{pool_name} with #{pool_state.size} workers...")

        # Start workers for this pool
        workers =
          start_workers_concurrently(
            pool_name,
            pool_state.size,
            pool_state.startup_timeout,
            pool_state.worker_module,
            pool_state.adapter_module,
            pool_state.pool_config
          )

        SLog.info(
          "✅ Pool #{pool_name}: Initialized #{length(workers)}/#{pool_state.size} workers"
        )

        # Update pool state with workers
        updated_pool_state =
          if length(workers) > 0 do
            available = MapSet.new(workers)

            %{pool_state | workers: workers, available: available, initialized: true}
          else
            # Pool failed to start any workers
            SLog.error("❌ Pool #{pool_name} failed to start any workers!")
            pool_state
          end

        {pool_name, updated_pool_state}
      end)
      |> Enum.into(%{})

    elapsed = System.monotonic_time(:millisecond) - start_time

    # DIAGNOSTIC: Capture peak system resource usage after startup
    peak_resources = capture_resource_metrics()
    resource_delta = calculate_resource_delta(baseline_resources, peak_resources)

    SLog.info("✅ All pools initialized in #{elapsed}ms")
    SLog.info("📊 Resource usage delta: #{inspect(resource_delta)}")

    # Check if any pool successfully started
    any_workers_started? =
      Enum.any?(updated_pools, fn {_name, pool} -> length(pool.workers) > 0 end)

    if not any_workers_started? do
      {:stop, :no_workers_started, state}
    else
      new_state = %{state | pools: updated_pools}

      # PERFORMANCE FIX: Stagger replies to waiters from ALL pools
      all_waiters =
        Enum.flat_map(updated_pools, fn {_name, pool} ->
          pool.initialization_waiters
        end)

      all_waiters
      |> Enum.with_index()
      |> Enum.each(fn {from, index} ->
        # Stagger each reply by 2ms to spread the load
        Process.send_after(self(), {:reply_to_waiter, from}, index * 2)
      end)

      # Clear all initialization_waiters
      updated_pools_no_waiters =
        Enum.map(updated_pools, fn {name, pool} ->
          {name, %{pool | initialization_waiters: []}}
        end)
        |> Enum.into(%{})

      {:noreply, %{new_state | pools: updated_pools_no_waiters}}
    end
  end

  @impl true
  def handle_call({:execute, command, args, opts}, from, state) do
    # Backward compatibility: route to default pool
    pool_name = opts[:pool_name] || state.default_pool
    handle_execute_for_pool(pool_name, command, args, opts, from, state)
  end

  def handle_call({:execute, pool_name, command, args, opts}, from, state) do
    handle_execute_for_pool(pool_name, command, args, opts, from, state)
  end

  def handle_call({:checkout_worker, session_id}, _from, state) do
    # Backward compat: use default pool
    pool_name = state.default_pool

    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        # Pass affinity_cache from top-level state
        case checkout_worker(pool_state, session_id, state.affinity_cache) do
          {:ok, worker_id, new_pool_state} ->
            updated_pools = Map.put(state.pools, pool_name, new_pool_state)
            {:reply, {:ok, worker_id}, %{state | pools: updated_pools}}

          {:error, :no_workers} ->
            {:reply, {:error, :no_workers_available}, state}
        end
    end
  end

  def handle_call(:get_stats, _from, state) do
    # Backward compat: aggregate stats from all pools
    aggregate_stats =
      Enum.reduce(
        state.pools,
        %{
          requests: 0,
          queued: 0,
          errors: 0,
          queue_timeouts: 0,
          pool_saturated: 0,
          workers: 0,
          available: 0,
          busy: 0
        },
        fn {_name, pool}, acc ->
          %{
            requests: acc.requests + Map.get(pool.stats, :requests, 0),
            queued: acc.queued + Map.get(pool.stats, :queued, 0) + :queue.len(pool.request_queue),
            errors: acc.errors + Map.get(pool.stats, :errors, 0),
            queue_timeouts: acc.queue_timeouts + Map.get(pool.stats, :queue_timeouts, 0),
            pool_saturated: acc.pool_saturated + Map.get(pool.stats, :pool_saturated, 0),
            workers: acc.workers + length(pool.workers),
            available: acc.available + MapSet.size(pool.available),
            busy: acc.busy + map_size(pool.busy)
          }
        end
      )

    {:reply, aggregate_stats, state}
  end

  def handle_call({:get_stats, pool_name}, _from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        stats =
          Map.merge(pool_state.stats, %{
            workers: length(pool_state.workers),
            available: MapSet.size(pool_state.available),
            busy: map_size(pool_state.busy),
            queued: :queue.len(pool_state.request_queue)
          })

        {:reply, stats, state}
    end
  end

  def handle_call(:list_workers, _from, state) do
    # Backward compat: return workers from ALL pools
    all_workers =
      Enum.flat_map(state.pools, fn {_name, pool} ->
        pool.workers
      end)

    {:reply, all_workers, state}
  end

  def handle_call({:list_workers, pool_name}, _from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        {:reply, pool_state.workers, state}
    end
  end

  @impl true
  def handle_call(:await_ready, from, state) do
    # Backward compat: wait for ALL pools to be initialized
    all_initialized? =
      Enum.all?(state.pools, fn {_name, pool} -> pool.initialized end)

    if all_initialized? do
      {:reply, :ok, state}
    else
      # Add waiter to ALL uninitialized pools
      updated_pools =
        Enum.map(state.pools, fn {name, pool} ->
          if pool.initialized do
            {name, pool}
          else
            {name, %{pool | initialization_waiters: [from | pool.initialization_waiters]}}
          end
        end)
        |> Enum.into(%{})

      {:noreply, %{state | pools: updated_pools}}
    end
  end

  def handle_call({:await_ready, pool_name}, from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        if pool_state.initialized do
          {:reply, :ok, state}
        else
          # Add waiter to this pool
          updated_pool = %{
            pool_state
            | initialization_waiters: [from | pool_state.initialization_waiters]
          }

          updated_pools = Map.put(state.pools, pool_name, updated_pool)
          {:noreply, %{state | pools: updated_pools}}
        end
    end
  end

  @impl true
  def handle_call({:worker_ready, worker_id}, _from, state) do
    SLog.info("Worker #{worker_id} reported ready. Processing queued work.")

    # Find which pool this worker belongs to by worker_id prefix
    pool_name = extract_pool_name_from_worker_id(worker_id)

    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error("Worker #{worker_id} reported ready but pool #{pool_name} not found!")
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        # Ensure worker is in workers list
        new_workers =
          if Enum.member?(pool_state.workers, worker_id) do
            pool_state.workers
          else
            [worker_id | pool_state.workers]
          end

        updated_pool_state = %{pool_state | workers: new_workers}

        # CRITICAL FIX: Immediately drive the queue by treating this as a checkin
        GenServer.cast(self(), {:checkin_worker, pool_name, worker_id})

        updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
        {:reply, :ok, %{state | pools: updated_pools}}
    end
  end

  defp handle_execute_for_pool(pool_name, command, args, opts, from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, {:pool_not_found, pool_name}}, state}

      pool_state ->
        if not pool_state.initialized do
          {:reply, {:error, :pool_not_initialized}, state}
        else
          session_id = opts[:session_id]

          # Pass affinity_cache from top-level state
          case checkout_worker(pool_state, session_id, state.affinity_cache) do
            {:ok, worker_id, new_pool_state} ->
              # Execute in a supervised, unlinked task
              Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
                # Extract the actual PID from the from tuple for monitoring
                {client_pid, _tag} = from
                ref = Process.monitor(client_pid)

                # Track execution time
                start_time = System.monotonic_time(:microsecond)
                result = execute_on_worker(worker_id, command, args, opts)
                duration_us = System.monotonic_time(:microsecond) - start_time

                # Emit telemetry for request execution
                :telemetry.execute(
                  [:snakepit, :request, :executed],
                  %{duration_us: duration_us},
                  %{
                    pool: pool_name,
                    worker_id: worker_id,
                    command: command,
                    success: match?({:ok, _}, result)
                  }
                )

                # Check if the client is still alive
                receive do
                  {:DOWN, ^ref, :process, ^client_pid, _reason} ->
                    # Client is dead, don't try to reply. Just check in the worker.
                    SLog.warning(
                      "Client #{inspect(client_pid)} died before receiving reply. Checking in worker #{worker_id}."
                    )

                    GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
                after
                  0 ->
                    # Client is alive. Clean up the monitor and proceed.
                    Process.demonitor(ref, [:flush])
                    GenServer.reply(from, result)
                    GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
                end
              end)

              # Update pool state and stats
              updated_pool_state = %{
                new_pool_state
                | stats: Map.update!(new_pool_state.stats, :requests, &(&1 + 1))
              }

              updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
              # We reply :noreply immediately, the task will reply to the caller later
              {:noreply, %{state | pools: updated_pools}}

            {:error, :no_workers} ->
              # Check if queue is at max capacity
              current_queue_size = :queue.len(pool_state.request_queue)

              if current_queue_size >= pool_state.max_queue_size do
                # Pool is saturated, reject request immediately
                updated_pool_state = %{
                  pool_state
                  | stats: Map.update!(pool_state.stats, :pool_saturated, &(&1 + 1))
                }

                # Emit telemetry for saturation
                :telemetry.execute(
                  [:snakepit, :pool, :saturated],
                  %{queue_size: current_queue_size, max_queue_size: pool_state.max_queue_size},
                  %{
                    pool: pool_name,
                    available_workers: MapSet.size(pool_state.available),
                    busy_workers: map_size(pool_state.busy)
                  }
                )

                updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
                {:reply, {:error, :pool_saturated}, %{state | pools: updated_pools}}
              else
                # Queue the request
                request = {from, command, args, opts, System.monotonic_time()}
                new_queue = :queue.in(request, pool_state.request_queue)

                # Update stats
                updated_stats =
                  pool_state.stats
                  |> Map.update!(:requests, &(&1 + 1))
                  |> Map.update!(:queued, &(&1 + 1))

                updated_pool_state = %{
                  pool_state
                  | request_queue: new_queue,
                    stats: updated_stats
                }

                # Set queue timeout
                Process.send_after(
                  self(),
                  {:queue_timeout, pool_name, from},
                  pool_state.queue_timeout
                )

                updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
                {:noreply, %{state | pools: updated_pools}}
              end
          end
        end
    end
  end

  # checkin_worker - WITH pool_name parameter
  @impl true
  def handle_cast({:checkin_worker, pool_name, worker_id}, state) when is_atom(pool_name) do
    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error("checkin_worker: pool #{pool_name} not found!")
        {:noreply, state}

      pool_state ->
        case :queue.out(pool_state.request_queue) do
          {{:value, {queued_from, command, args, opts, _queued_at}}, new_queue} ->
            if MapSet.member?(pool_state.cancelled_requests, queued_from) do
              SLog.debug("Skipping cancelled request from #{inspect(queued_from)}")
              new_cancelled = MapSet.delete(pool_state.cancelled_requests, queued_from)

              updated_pool_state = %{
                pool_state
                | request_queue: new_queue,
                  cancelled_requests: new_cancelled
              }

              GenServer.cast(self(), {:checkin_worker, pool_name, worker_id})
              updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
              {:noreply, %{state | pools: updated_pools}}
            else
              {client_pid, _tag} = queued_from

              if Process.alive?(client_pid) do
                Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
                  ref = Process.monitor(client_pid)
                  result = execute_on_worker(worker_id, command, args, opts)

                  receive do
                    {:DOWN, ^ref, :process, ^client_pid, _reason} ->
                      SLog.warning(
                        "Queued client #{inspect(client_pid)} died during execution."
                      )

                      GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
                  after
                    0 ->
                      Process.demonitor(ref, [:flush])
                      GenServer.reply(queued_from, result)
                      GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
                  end
                end)

                updated_pool_state = %{pool_state | request_queue: new_queue}
                updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
                {:noreply, %{state | pools: updated_pools}}
              else
                SLog.debug("Discarding request from dead client #{inspect(client_pid)}")
                GenServer.cast(self(), {:checkin_worker, pool_name, worker_id})
                updated_pool_state = %{pool_state | request_queue: new_queue}
                updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
                {:noreply, %{state | pools: updated_pools}}
              end
            end

          {:empty, _} ->
            new_available = MapSet.put(pool_state.available, worker_id)
            new_busy = Map.delete(pool_state.busy, worker_id)
            updated_pool_state = %{pool_state | available: new_available, busy: new_busy}
            updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
            {:noreply, %{state | pools: updated_pools}}
        end
    end
  end

  # Legacy checkin_worker WITHOUT pool_name (infer from worker_id)
  def handle_cast({:checkin_worker, worker_id}, state) do
    pool_name = extract_pool_name_from_worker_id(worker_id)
    handle_cast({:checkin_worker, pool_name, worker_id}, state)
  end

  # queue_timeout - WITH pool_name
  @impl true
  def handle_info({:queue_timeout, pool_name, from}, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:noreply, state}

      pool_state ->
        GenServer.reply(from, {:error, :queue_timeout})
        new_cancelled = MapSet.put(pool_state.cancelled_requests, from)
        updated_stats = Map.update!(pool_state.stats, :queue_timeouts, &(&1 + 1))

        updated_pool_state = %{
          pool_state
          | cancelled_requests: new_cancelled,
            stats: updated_stats
        }

        updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
        {:noreply, %{state | pools: updated_pools}}
    end
  end

  # Legacy queue_timeout WITHOUT pool_name
  def handle_info({:queue_timeout, from}, state) do
    handle_info({:queue_timeout, state.default_pool, from}, state)
  end

  # Worker death - find which pool it belongs to
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Snakepit.Pool.Registry.get_worker_id_by_pid(pid) do
      {:error, :not_found} ->
        {:noreply, state}

      {:ok, worker_id} ->
        SLog.error("Worker #{worker_id} (pid: #{inspect(pid)}) died: #{inspect(reason)}")
        :ets.match_delete(state.affinity_cache, {:_, worker_id, :_})

        pool_name = extract_pool_name_from_worker_id(worker_id)

        case Map.get(state.pools, pool_name) do
          nil ->
            SLog.warning("Dead worker #{worker_id} belongs to unknown pool #{pool_name}")
            {:noreply, state}

          pool_state ->
            new_workers = List.delete(pool_state.workers, worker_id)
            new_available = MapSet.delete(pool_state.available, worker_id)
            new_busy = Map.delete(pool_state.busy, worker_id)

            updated_pool_state = %{
              pool_state
              | workers: new_workers,
                available: new_available,
                busy: new_busy
            }

            updated_pools = Map.put(state.pools, pool_name, updated_pool_state)

            SLog.debug("Removed dead worker #{worker_id} from pool #{pool_name}")
            {:noreply, %{state | pools: updated_pools}}
        end
    end
  end

  @impl true
  def handle_info({:reply_to_waiter, from}, state) do
    # PERFORMANCE FIX: Staggered reply to avoid thundering herd
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  @doc false
  # Handles completion messages from tasks started via Task.Supervisor.async_nolink.
  # These are used for fire-and-forget operations (like replying to callers or
  # kicking off worker respawns), so we can safely ignore the completion message.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    SLog.debug("Pool received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    SLog.info("🛑 Pool manager terminating with reason: #{inspect(reason)}.")

    # Log state of pools during shutdown (debug level)
    Enum.each(state.pools, fn {pool_name, pool_state} ->
      SLog.debug("""
      Pool #{pool_name} shutdown state:
        Initialized: #{pool_state.initialized}
        Workers: #{length(pool_state.workers)}
        Available: #{MapSet.size(pool_state.available)}
        Busy: #{map_size(pool_state.busy)}
        Queued: #{:queue.len(pool_state.request_queue)}
        Waiters: #{length(pool_state.initialization_waiters)}
      """)

      if length(pool_state.initialization_waiters) > 0 do
        SLog.warning(
          "Pool #{pool_name}: #{length(pool_state.initialization_waiters)} processes still waiting for pool init!"
        )
      end
    end)

    # Supervision tree will handle worker shutdown via WorkerSupervisor
    :ok
  end

  # REMOVE the wait_for_ports_to_exit/2 helper functions.

  # Private Functions

  defp start_workers_concurrently(
         pool_name,
         count,
         startup_timeout,
         worker_module,
         adapter_module,
         pool_config
       ) do
    # SAFETY CHECK: Enforce maximum worker limit to prevent resource exhaustion
    legacy_pool_config = Application.get_env(:snakepit, :pool_config, %{})

    max_workers =
      Map.get(pool_config, :max_workers) || Map.get(legacy_pool_config, :max_workers, 150)

    actual_count = min(count, max_workers)

    if actual_count < count do
      SLog.warning(
        "⚠️  Requested #{count} workers but limiting to #{actual_count} (max_workers=#{max_workers})"
      )

      SLog.warning(
        "⚠️  To increase this limit, set :pool_config.max_workers in config/config.exs"
      )
    end

    SLog.info("🚀 Starting concurrent initialization of #{actual_count} workers...")
    SLog.info("📦 Using worker type: #{inspect(worker_module)}")

    # CRITICAL FIX: Get pool's registered name or PID for worker notifications
    # This ensures workers notify the correct pool instance (important for test isolation)
    pool_genserver_name =
      case Process.info(self(), :registered_name) do
        {:registered_name, name} -> name
        nil -> self()
      end

    # CRITICAL FIX: Batch worker startup to prevent {:eagain} fork bomb
    # Get batch configuration (check pool_config first, then legacy)
    batch_size =
      Map.get(pool_config, :startup_batch_size) ||
        Map.get(legacy_pool_config, :startup_batch_size, 10)

    batch_delay =
      Map.get(pool_config, :startup_batch_delay_ms) ||
        Map.get(legacy_pool_config, :startup_batch_delay_ms, 500)

    # Split workers into batches
    1..actual_count
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, batch_num} ->
      batch_start = batch_num * batch_size + 1
      batch_end = min(batch_start + length(batch) - 1, actual_count)
      SLog.info("Starting batch #{batch_num + 1}: workers #{batch_start}-#{batch_end}")

      # Start this batch concurrently
      workers =
        batch
        |> Task.async_stream(
          fn i ->
            worker_id = "#{pool_name}_worker_#{i}_#{:erlang.unique_integer([:positive])}"

            # v0.6.0: Use WorkerProfile if pool_config has worker_profile, else legacy
            result =
              if Map.has_key?(pool_config, :worker_profile) do
                # NEW v0.6.0 path: Use WorkerProfile system
                profile_module = Snakepit.Config.get_profile_module(pool_config)

                # Build worker_config with all necessary fields
                worker_config =
                  pool_config
                  |> Map.put(:worker_id, worker_id)
                  |> Map.put(:worker_module, worker_module)
                  |> Map.put(:adapter_module, adapter_module)
                  |> Map.put(:pool_name, pool_genserver_name)

                # Call profile's start_worker
                profile_module.start_worker(worker_config)
              else
                # LEGACY v0.5.x path: Direct WorkerSupervisor call
                Snakepit.Pool.WorkerSupervisor.start_worker(
                  worker_id,
                  worker_module,
                  adapter_module,
                  pool_genserver_name
                )
              end

            case result do
              {:ok, _pid} ->
                SLog.info("✅ Worker #{i}/#{actual_count} ready: #{worker_id}")
                worker_id

              {:error, reason} ->
                SLog.error("❌ Worker #{i}/#{actual_count} failed: #{inspect(reason)}")
                nil
            end
          end,
          timeout: startup_timeout,
          max_concurrency: batch_size,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, worker_id} ->
            worker_id

          {:exit, reason} ->
            SLog.error("Worker startup task failed: #{inspect(reason)}")
            nil
        end)
        |> Enum.filter(&(&1 != nil))

      # Delay between batches (unless this is the last batch)
      unless batch_num == div(actual_count - 1, batch_size) do
        :timer.sleep(batch_delay)
      end

      workers
    end)
  end

  defp checkout_worker(pool_state, session_id, affinity_cache) do
    case try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
      {:ok, worker_id, new_state} ->
        {:ok, worker_id, new_state}

      :no_preferred_worker ->
        # Simple checkout from available set
        # Workers only enter this set after {:worker_ready} event, ensuring they're ready
        case Enum.take(pool_state.available, 1) do
          [worker_id] ->
            new_available = MapSet.delete(pool_state.available, worker_id)
            new_busy = Map.put(pool_state.busy, worker_id, true)
            new_pool_state = %{pool_state | available: new_available, busy: new_busy}

            # Store session affinity if we have a session_id
            if session_id do
              store_session_affinity(session_id, worker_id)
            end

            {:ok, worker_id, new_pool_state}

          [] ->
            {:error, :no_workers}
        end
    end
  end

  defp try_checkout_preferred_worker(_pool_state, nil, _affinity_cache), do: :no_preferred_worker

  defp try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
    # PERFORMANCE FIX: Use shared affinity_cache from top-level state
    case get_preferred_worker(session_id, affinity_cache) do
      {:ok, preferred_worker_id} ->
        # Check if preferred worker is available
        if MapSet.member?(pool_state.available, preferred_worker_id) do
          # Remove the preferred worker from available set
          new_available = MapSet.delete(pool_state.available, preferred_worker_id)
          new_busy = Map.put(pool_state.busy, preferred_worker_id, true)
          new_pool_state = %{pool_state | available: new_available, busy: new_busy}

          SLog.debug("Using preferred worker #{preferred_worker_id} for session #{session_id}")
          {:ok, preferred_worker_id, new_pool_state}
        else
          :no_preferred_worker
        end

      {:error, :not_found} ->
        :no_preferred_worker
    end
  end

  # PERFORMANCE FIX: ETS-cached session affinity lookup
  # Eliminates GenServer bottleneck by caching session->worker mappings with TTL
  defp get_preferred_worker(session_id, cache_table) do
    current_time = System.monotonic_time(:second)

    # Try cache first (O(1), no GenServer call)
    case :ets.lookup(cache_table, session_id) do
      [{^session_id, worker_id, expires_at}] when expires_at > current_time ->
        # Cache hit! ~100x faster than GenServer.call
        {:ok, worker_id}

      _ ->
        # Cache miss or expired - fetch from SessionStore and cache result
        case Snakepit.Bridge.SessionStore.get_session(session_id) do
          {:ok, session} ->
            case Map.get(session, :last_worker_id) do
              nil ->
                {:error, :not_found}

              worker_id ->
                # Cache for 60 seconds to avoid repeated GenServer calls
                expires_at = current_time + 60
                :ets.insert(cache_table, {session_id, worker_id, expires_at})
                {:ok, worker_id}
            end

          {:error, :not_found} ->
            {:error, :not_found}
        end
    end
  end

  defp store_session_affinity(session_id, worker_id) do
    # Store the worker affinity in a supervised task for better error logging
    Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
      :ok = Snakepit.Bridge.SessionStore.store_worker_session(session_id, worker_id)
      SLog.debug("Stored session affinity: #{session_id} -> #{worker_id}")
      :ok
    end)
  end

  defp execute_on_worker(worker_id, command, args, opts) do
    timeout = get_command_timeout(command, args, opts)
    worker_module = get_worker_module(worker_id)

    try do
      result = worker_module.execute(worker_id, command, args, timeout)

      # Increment request count for lifecycle management (on success only)
      case result do
        {:ok, _} ->
          Snakepit.Worker.LifecycleManager.increment_request_count(worker_id)

        _ ->
          :ok
      end

      result
    catch
      :exit, {:timeout, _} ->
        {:error, :worker_timeout}

      :exit, reason ->
        {:error, {:worker_exit, reason}}
    end
  end

  defp get_worker_module(worker_id) do
    # Try to determine the worker module from registry or configuration
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{_pid, %{worker_module: module}}] ->
        module

      _ ->
        # Fallback: use GRPCWorker
        Snakepit.GRPCWorker
    end
  end

  defp get_command_timeout(command, args, opts) do
    # Prefer explicit client timeout, then adapter timeout, then global default
    case opts[:timeout] do
      nil ->
        case get_adapter_timeout(command, args) do
          # Global default
          nil -> 30_000
          adapter_timeout -> adapter_timeout
        end

      client_timeout ->
        client_timeout
    end
  end

  defp get_adapter_timeout(command, args) do
    case Application.get_env(:snakepit, :adapter_module) do
      nil ->
        nil

      adapter_module ->
        if function_exported?(adapter_module, :command_timeout, 2) do
          try do
            adapter_module.command_timeout(command, args)
          rescue
            # Fall back to default if adapter timeout fails
            _ -> nil
          end
        else
          nil
        end
    end
  end

  # DIAGNOSTIC: Resource monitoring helpers
  defp capture_resource_metrics do
    %{
      beam_processes: length(:erlang.processes()),
      beam_ports: length(:erlang.ports()),
      memory_total_mb: div(:erlang.memory(:total), 1_024 * 1_024),
      memory_processes_mb: div(:erlang.memory(:processes), 1_024 * 1_024),
      ets_tables: length(:ets.all()),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  defp calculate_resource_delta(baseline, peak) do
    %{
      processes_delta: peak.beam_processes - baseline.beam_processes,
      ports_delta: peak.beam_ports - baseline.beam_ports,
      memory_delta_mb: peak.memory_total_mb - baseline.memory_total_mb,
      memory_processes_delta_mb: peak.memory_processes_mb - baseline.memory_processes_mb,
      ets_tables_delta: peak.ets_tables - baseline.ets_tables,
      time_elapsed_ms: peak.timestamp - baseline.timestamp
    }
  end

  # Helper to extract pool_name from worker_id
  defp extract_pool_name_from_worker_id(worker_id) do
    # Worker IDs are formatted as: "pool_name_worker_N_unique"
    case String.split(worker_id, "_worker_", parts: 2) do
      [pool_name_str, _rest] ->
        String.to_existing_atom(pool_name_str)

      _ ->
        :default
    end
  catch
    _, _ -> :default
  end
end
