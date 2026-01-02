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
  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Config
  alias Snakepit.CrashBarrier
  alias Snakepit.Defaults
  alias Snakepit.Error
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Logger.Redaction
  alias Snakepit.Pool.Initializer
  alias Snakepit.Pool.Queue
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.State
  alias Snakepit.Worker.LifecycleManager
  alias Snakepit.WorkerProfile.Thread.CapacityStore

  @log_category :pool

  # Top-level state structure
  defstruct [
    :pools,
    # Map of pool_name => State
    :affinity_cache,
    # Shared across all pools
    :default_pool,
    # Default pool name for backward compatibility
    initializing: false,
    # Set to true while async initialization is in progress
    init_start_time: nil
    # Timestamp for measuring initialization duration
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
    timeout = opts[:timeout] || Defaults.pool_request_timeout()

    # Store deadline_ms for queue-aware remaining-time calculations
    deadline_ms = System.monotonic_time(:millisecond) + timeout
    opts_with_deadline = Keyword.put(opts, :deadline_ms, deadline_ms)

    try do
      GenServer.call(pool, {:execute, command, args, opts_with_deadline}, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error,
         Error.timeout_error("Pool execute timed out", %{
           timeout_ms: timeout,
           command: command
         })}
    end
  end

  # ============================================================================
  # Timeout Helpers (Public API for deadline-aware timeout derivation)
  # ============================================================================

  @doc """
  Returns the default timeout for a given call type.

  ## Call types
  - `:execute` - Regular execute operations
  - `:execute_stream` - Streaming operations
  - `:queue` - Queue wait operations

  ## Examples

      iex> Snakepit.Pool.get_default_timeout_for_call(:execute, %{}, [])
      300_000  # from default_timeout()

      iex> Snakepit.Pool.get_default_timeout_for_call(:execute, %{}, [timeout: 45_000])
      45_000
  """
  @spec get_default_timeout_for_call(atom(), map(), Keyword.t()) :: timeout()
  def get_default_timeout_for_call(call_type, _args, opts) do
    case Keyword.get(opts, :timeout) do
      nil -> get_timeout_for_call_type(call_type)
      explicit_timeout -> explicit_timeout
    end
  end

  defp get_timeout_for_call_type(:execute), do: Defaults.default_timeout()
  defp get_timeout_for_call_type(:execute_stream), do: Defaults.stream_timeout()
  defp get_timeout_for_call_type(:queue), do: Defaults.queue_timeout()
  defp get_timeout_for_call_type(_), do: Defaults.default_timeout()

  @doc """
  Derives the RPC timeout from opts, considering deadline if present.

  When a request has been queued, time has already elapsed. This function
  calculates the remaining time budget for the actual RPC call.

  ## Examples

      # Fresh request with 60s budget
      iex> Snakepit.Pool.derive_rpc_timeout_from_opts([], 60_000)
      58_800  # 60_000 - 1000 - 200 margins

      # Request that waited 500ms in queue
      iex> now = System.monotonic_time(:millisecond)
      iex> opts = [deadline_ms: now + 59_500]
      iex> Snakepit.Pool.derive_rpc_timeout_from_opts(opts, 60_000)
      # ~= 58_300 (remaining - margins)
  """
  @spec derive_rpc_timeout_from_opts(Keyword.t(), timeout()) :: timeout()
  def derive_rpc_timeout_from_opts(_opts, :infinity), do: :infinity

  def derive_rpc_timeout_from_opts(opts, default_timeout) when is_integer(default_timeout) do
    case Keyword.get(opts, :deadline_ms) do
      nil ->
        # No deadline set, use full budget
        Defaults.rpc_timeout(default_timeout)

      deadline_ms ->
        # Calculate remaining time
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now
        # Apply margins and floor
        Defaults.rpc_timeout(max(remaining, 1))
    end
  end

  @doc """
  Computes effective queue timeout considering deadline.

  If a deadline is set and less time remains than the configured queue timeout,
  returns the remaining time instead.

  ## Examples

      # No deadline - use configured queue timeout
      iex> Snakepit.Pool.effective_queue_timeout_ms([], 10_000)
      10_000

      # Deadline with 5s remaining - use remaining time
      iex> now = System.monotonic_time(:millisecond)
      iex> opts = [deadline_ms: now + 5_000]
      iex> Snakepit.Pool.effective_queue_timeout_ms(opts, 10_000)
      # ~= 5_000 (remaining time)
  """
  @spec effective_queue_timeout_ms(Keyword.t(), timeout()) :: non_neg_integer()
  def effective_queue_timeout_ms(opts, configured_queue_timeout) do
    case Keyword.get(opts, :deadline_ms) do
      nil ->
        configured_queue_timeout

      deadline_ms ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now
        max(remaining, 0)
    end
  end

  @doc """
  Execute a streaming command with callback.
  """
  def execute_stream(command, args, callback_fn, opts \\ []) do
    pool = opts[:pool] || __MODULE__
    timeout = opts[:timeout] || Defaults.pool_streaming_timeout()
    pool_identifier = opts[:pool_name] || pool
    SLog.debug(@log_category, "[Pool] execute_stream #{command} with #{Redaction.describe(args)}")

    case checkout_worker_for_stream(pool, opts) do
      {:ok, worker_id} ->
        SLog.debug(@log_category, "[Pool] Checked out worker #{worker_id} for streaming")

        start_time = System.monotonic_time(:microsecond)

        result =
          try do
            execute_on_worker_stream(worker_id, command, args, callback_fn, timeout)
          after
            # This block ALWAYS executes, preventing worker leaks on crashes
            SLog.debug(
              @log_category,
              "[Pool] Checking in worker #{worker_id} after stream execution"
            )

            checkin_worker(pool, worker_id)
          end

        emit_stream_telemetry(pool_identifier, worker_id, command, result, start_time)
        result

      {:error, reason} ->
        SLog.error(
          @log_category,
          "[Pool] Failed to checkout worker for streaming: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp checkout_worker_for_stream(pool, opts) do
    timeout = opts[:checkout_timeout] || Defaults.checkout_timeout()
    GenServer.call(pool, {:checkout_worker, opts[:session_id]}, timeout)
  end

  defp checkin_worker(pool, worker_id) do
    GenServer.cast(pool, {:checkin_worker, worker_id})
  end

  defp execute_on_worker_stream(worker_id, command, args, callback_fn, timeout) do
    worker_module = get_worker_module(worker_id)
    SLog.debug(@log_category, "[Pool] execute_on_worker_stream using #{inspect(worker_module)}")

    if function_exported?(worker_module, :execute_stream, 5) do
      SLog.debug(
        @log_category,
        "[Pool] Invoking #{worker_module}.execute_stream with timeout #{timeout}"
      )

      result = worker_module.execute_stream(worker_id, command, args, callback_fn, timeout)
      SLog.debug(@log_category, "[Pool] execute_stream result: #{Redaction.describe(result)}")
      result
    else
      SLog.error(
        @log_category,
        "[Pool] Worker module #{worker_module} does not export execute_stream/5"
      )

      {:error,
       Error.worker_error("Streaming not supported by worker", %{
         worker_module: worker_module,
         worker_id: worker_id
       })}
    end
  end

  defp emit_stream_telemetry(pool_identifier, worker_id, command, result, start_time) do
    duration_us = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:snakepit, :request, :executed],
      %{duration_us: duration_us},
      %{
        pool: pool_identifier,
        worker_id: worker_id,
        command: command,
        success: result == :ok,
        streaming: true
      }
    )
  end

  @doc """
  Gets pool statistics.
  """
  def get_stats(pool \\ __MODULE__) do
    GenServer.call(pool, :get_stats)
  end

  @doc """
  Gets statistics for a specific pool name.
  """
  def get_stats(pool, pool_name) when is_atom(pool_name) do
    GenServer.call(pool, {:get_stats, pool_name})
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

  Returns `:ok` when all workers are ready, or `{:error, %Snakepit.Error{}}` if
  the pool doesn't initialize within the given timeout.
  """
  @spec await_ready(atom() | pid(), timeout() | nil) :: :ok | {:error, Error.t()}
  def await_ready(pool \\ __MODULE__, timeout \\ nil)

  def await_ready(pool, nil), do: await_ready(pool, Defaults.pool_await_ready_timeout())

  def await_ready(pool, timeout) do
    GenServer.call(pool, :await_ready, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error,
       Error.timeout_error("Pool initialization timed out", %{
         pool: pool,
         timeout_ms: timeout
       })}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # CRITICAL: Trap exits to ensure terminate/2 is called
    Process.flag(:trap_exit, true)

    case resolve_pool_configs() do
      {:ok, pool_configs} ->
        init_with_configs(opts, pool_configs)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_with_configs(opts, pool_configs) do
    # PERFORMANCE FIX: Create ETS cache for session affinity to eliminate
    # GenServer bottleneck on SessionStore. This provides ~100x faster lookups.
    # Shared across ALL pools
    affinity_cache =
      :ets.new(:worker_affinity_cache, [
        :set,
        :public,
        {:read_concurrency, true}
      ])

    # Check if we're in multi-pool mode (explicit :pools config)
    multi_pool_mode? = Application.get_env(:snakepit, :pools) != nil

    # Create initial pool states (not yet initialized with workers)
    pools =
      Enum.reduce(pool_configs, %{}, fn pool_config, acc ->
        pool_state = State.build_pool_state(opts, pool_config, multi_pool_mode?)
        Map.put(acc, pool_state.name, pool_state)
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
    Initializer.run(state)
  end

  # Handle completion of async pool initialization
  @impl true
  def handle_info({:pool_init_complete, updated_pools}, state) do
    elapsed = System.monotonic_time(:millisecond) - (state.init_start_time || 0)

    # DIAGNOSTIC: Capture peak system resource usage after startup
    peak_resources = Initializer.capture_resource_metrics()
    baseline_resources = Initializer.capture_resource_metrics()
    resource_delta = Initializer.calculate_resource_delta(baseline_resources, peak_resources)

    SLog.info(@log_category, "✅ All pools initialized in #{elapsed}ms")
    SLog.info(@log_category, "📊 Resource usage delta: #{inspect(resource_delta)}")

    failed_pools =
      Enum.filter(updated_pools, fn {_name, pool} -> Enum.empty?(pool.workers) end)

    failed_pool_names = Enum.map(failed_pools, &elem(&1, 0))

    if not Enum.empty?(failed_pools) do
      SLog.warning(
        @log_category,
        "⚠️ Pools with zero initialized workers: #{Enum.map_join(failed_pool_names, ", ", &to_string/1)}"
      )
    end

    # Check if any pool successfully started
    any_workers_started? =
      Enum.any?(updated_pools, fn {_name, pool} -> not Enum.empty?(pool.workers) end)

    if any_workers_started? do
      # CRITICAL: Get waiters from state.pools (GenServer state), NOT from updated_pools
      # (which was returned from the spawned init process and doesn't have waiters)
      all_waiters =
        Enum.flat_map(state.pools, fn {_name, pool} ->
          pool.initialization_waiters
        end)

      # PERFORMANCE FIX: Stagger replies to waiters from ALL pools
      all_waiters
      |> Enum.with_index()
      |> Enum.each(fn {from, index} ->
        # Stagger each reply by 2ms to spread the load
        Process.send_after(self(), {:reply_to_waiter, from}, index * 2)
      end)

      # Merge updated_pools (workers, capacities, initialized status) with cleared waiters
      merged_pools =
        Enum.map(updated_pools, fn {name, updated_pool} ->
          {name, %{updated_pool | initialization_waiters: []}}
        end)
        |> Enum.into(%{})

      new_state = %{state | pools: merged_pools, initializing: false, init_start_time: nil}
      {:noreply, new_state}
    else
      SLog.error(
        @log_category,
        "❌ All configured pools failed to start workers (#{Enum.map_join(failed_pool_names, ", ", &to_string/1)})."
      )

      {:stop, :no_workers_started, state}
    end
  end

  # Handle EXIT from the init process during async initialization
  # This occurs when the GenServer is shutting down while initialization is in progress
  @impl true
  def handle_info({:EXIT, _pid, reason}, %{initializing: true} = state) do
    case reason do
      :normal ->
        # Init process completed normally but we haven't received the result yet
        # This shouldn't happen in normal operation
        {:noreply, state}

      :shutdown ->
        # Clean shutdown - supervisor is terminating
        SLog.info(@log_category, "Pool initialization interrupted by shutdown")
        {:stop, :shutdown, state}

      {:shutdown, _} ->
        # Clean shutdown with reason
        SLog.info(@log_category, "Pool initialization interrupted by shutdown")
        {:stop, :shutdown, state}

      :killed ->
        # Init process was killed (e.g., supervisor timeout)
        SLog.warning(@log_category, "Pool initialization process killed")
        {:stop, :killed, state}

      other ->
        # Init process crashed
        SLog.error(@log_category, "Pool initialization failed: #{inspect(other)}")
        {:stop, {:init_failed, other}, state}
    end
  end

  # Handle EXIT from other linked processes (workers, etc.) - passthrough
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Let the default behavior handle this
    {:noreply, state}
  end

  # queue_timeout - WITH pool_name
  def handle_info({:queue_timeout, pool_name, from}, state) do
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
        handle_worker_down(worker_id, pid, reason, state)
    end
  end

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
    SLog.debug(@log_category, "Pool received unexpected message: #{inspect(msg)}")
    {:noreply, state}
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

  def handle_call({:checkout_worker, pool_name, session_id}, _from, state)
      when is_atom(pool_name) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
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
            busy: acc.busy + busy_worker_count(pool)
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
            busy: busy_worker_count(pool_state),
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
    if all_pools_initialized?(state.pools) do
      {:reply, :ok, state}
    else
      updated_pools = add_waiter_to_uninitialized_pools(state.pools, from)
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

  def handle_call({:worker_ready, worker_id}, _from, state) do
    SLog.info(@log_category, "Worker #{worker_id} reported ready. Processing queued work.")

    # Find which pool this worker belongs to by worker_id prefix
    pool_name = extract_pool_name_from_worker_id(worker_id)

    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error(
          @log_category,
          "Worker #{worker_id} reported ready but pool #{pool_name} not found!"
        )

        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        # Ensure worker is in workers list
        new_workers =
          if Enum.member?(pool_state.workers, worker_id) do
            pool_state.workers
          else
            [worker_id | pool_state.workers]
          end

        updated_pool_state =
          pool_state
          |> Map.put(:workers, new_workers)
          |> State.ensure_worker_capacity(worker_id)
          |> State.ensure_worker_available(worker_id)

        # CRITICAL FIX: Immediately drive the queue by treating this as a checkin
        GenServer.cast(self(), {:checkin_worker, pool_name, worker_id, :skip_decrement})

        CrashBarrier.maybe_emit_restart(pool_name, worker_id)

        updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
        {:reply, :ok, %{state | pools: updated_pools}}
    end
  end

  defp all_pools_initialized?(pools) do
    Enum.all?(pools, fn {_name, pool} -> pool.initialized end)
  end

  defp add_waiter_to_uninitialized_pools(pools, from) do
    Enum.map(pools, fn {name, pool} ->
      if pool.initialized do
        {name, pool}
      else
        {name, %{pool | initialization_waiters: [from | pool.initialization_waiters]}}
      end
    end)
    |> Enum.into(%{})
  end

  defp handle_execute_for_pool(pool_name, command, args, opts, from, state) do
    with {:ok, pool_state} <- get_pool(state.pools, pool_name),
         :ok <- check_pool_initialized(pool_state) do
      handle_execute_in_pool(pool_name, pool_state, command, args, opts, from, state)
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

  defp handle_execute_in_pool(pool_name, pool_state, command, args, opts, from, state) do
    {request_queue, cancelled_requests} =
      Queue.compact_pool_queue(
        pool_state.request_queue,
        pool_state.cancelled_requests,
        pool_state.queue_timeout
      )

    pool_state = %{
      pool_state
      | request_queue: request_queue,
        cancelled_requests: cancelled_requests
    }

    session_id = opts[:session_id]

    case checkout_worker(pool_state, session_id, state.affinity_cache) do
      {:ok, worker_id, new_pool_state} ->
        execute_with_worker(
          pool_name,
          worker_id,
          new_pool_state,
          command,
          args,
          opts,
          from,
          state
        )

      {:error, :no_workers} ->
        handle_no_workers_available(pool_name, pool_state, command, args, opts, from, state)
    end
  end

  defp execute_with_worker(pool_name, worker_id, new_pool_state, command, args, opts, from, state) do
    spawn_execution_task(
      pool_name,
      worker_id,
      command,
      args,
      opts,
      from,
      new_pool_state.pool_config
    )

    updated_pool_state = %{
      new_pool_state
      | stats: Map.update!(new_pool_state.stats, :requests, &(&1 + 1))
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp spawn_execution_task(pool_name, worker_id, command, args, opts, from, pool_config) do
    async_with_context(fn ->
      {client_pid, _tag} = from
      ref = Process.monitor(client_pid)
      start_time = System.monotonic_time(:microsecond)

      case monitor_client_status(ref, client_pid) do
        {:down, reason} ->
          handle_client_already_down(pool_name, worker_id, command, ref, start_time, reason)

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

          handle_client_alive(exec_ctx, start_time)
      end
    end)
  end

  defp handle_client_already_down(pool_name, worker_id, command, ref, start_time, reason) do
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
    GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
  end

  defp handle_client_alive(exec_ctx, start_time) do
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
      execute_with_crash_barrier(
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

    handle_client_reply(pool_name, final_worker_id, from, ref, client_pid, result)
  end

  defp handle_client_reply(pool_name, worker_id, from, ref, client_pid, result) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, _reason} ->
        SLog.warning(
          @log_category,
          "Client #{inspect(client_pid)} died before receiving reply. " <>
            "Checking in worker #{inspect(worker_id)}."
        )

        maybe_checkin_worker(pool_name, worker_id)
    after
      0 ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        maybe_checkin_worker(pool_name, worker_id)
    end
  end

  defp maybe_checkin_worker(_pool_name, nil), do: :ok

  defp maybe_checkin_worker(pool_name, worker_id) do
    GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
  end

  defp handle_no_workers_available(pool_name, pool_state, command, args, opts, from, state) do
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

  # checkin_worker - WITH pool_name parameter
  @impl true
  def handle_cast({:checkin_worker, pool_name, worker_id, :skip_decrement}, state)
      when is_atom(pool_name) do
    do_handle_checkin(pool_name, worker_id, state, false)
  end

  def handle_cast({:checkin_worker, pool_name, worker_id}, state) when is_atom(pool_name) do
    do_handle_checkin(pool_name, worker_id, state, true)
  end

  # Legacy checkin_worker WITHOUT pool_name (infer from worker_id)
  def handle_cast({:checkin_worker, worker_id}, state) do
    pool_name = extract_pool_name_from_worker_id(worker_id)
    handle_cast({:checkin_worker, pool_name, worker_id}, state)
  end

  defp do_handle_checkin(pool_name, worker_id, state, decrement?) do
    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error(@log_category, "checkin_worker: pool #{pool_name} not found!")
        {:noreply, state}

      pool_state ->
        process_checkin(pool_name, worker_id, pool_state, state, decrement?)
    end
  end

  defp process_checkin(pool_name, worker_id, pool_state, state, decrement?) do
    now = System.monotonic_time(:millisecond)
    retention_ms = Queue.cancellation_retention_ms(pool_state.queue_timeout)

    pruned_cancelled =
      Queue.prune_cancelled_requests(pool_state.cancelled_requests, now, retention_ms)

    pool_state =
      if decrement? do
        updated_pool_state = State.decrement_worker_load(pool_state, worker_id)
        maybe_track_capacity(updated_pool_state, worker_id, :decrement)
        updated_pool_state
      else
        pool_state
      end

    process_next_queued_request(pool_name, worker_id, pool_state, pruned_cancelled, state)
  end

  defp process_next_queued_request(pool_name, worker_id, pool_state, pruned_cancelled, state) do
    case select_queue_worker(pool_state, worker_id) do
      {:ok, queue_worker} ->
        case :queue.out(pool_state.request_queue) do
          {{:value, request}, new_queue} ->
            handle_queued_request(
              pool_name,
              queue_worker,
              pool_state,
              request,
              new_queue,
              pruned_cancelled,
              state
            )

          {:empty, _} ->
            updated_pool_state = %{pool_state | cancelled_requests: pruned_cancelled}
            updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
            {:noreply, %{state | pools: updated_pools}}
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
         {queued_from, command, args, opts, _queued_at, timer_ref},
         new_queue,
         pruned_cancelled,
         state
       ) do
    Queue.cancel_queue_timer(timer_ref)

    ctx = %{
      pool_name: pool_name,
      worker_id: worker_id,
      pool_state: pool_state,
      queued_from: queued_from,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state
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

    if Process.alive?(client_pid) do
      execute_queued_request(ctx, client_pid, command, args, opts)
    else
      handle_dead_client(ctx, client_pid)
    end
  end

  defp execute_queued_request(ctx, client_pid, command, args, opts) do
    %{
      pool_name: pool_name,
      worker_id: worker_id,
      queued_from: queued_from,
      pool_state: pool_state,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state
    } = ctx

    pool_state = State.increment_worker_load(pool_state, worker_id)
    maybe_track_capacity(pool_state, worker_id, :increment)
    pool_pid = self()

    async_with_context(fn ->
      ref = Process.monitor(client_pid)

      {result, final_worker_id} =
        execute_with_crash_barrier(
          pool_pid,
          pool_name,
          worker_id,
          command,
          args,
          opts,
          pool_state.pool_config
        )

      checkin_worker_id = final_worker_id

      receive do
        {:DOWN, ^ref, :process, ^client_pid, _reason} ->
          SLog.warning(
            @log_category,
            "Queued client #{inspect(client_pid)} died during execution."
          )

          maybe_checkin_worker(pool_name, checkin_worker_id)
      after
        0 ->
          Process.demonitor(ref, [:flush])
          GenServer.reply(queued_from, result)
          maybe_checkin_worker(pool_name, checkin_worker_id)
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

  defp handle_dead_client(ctx, client_pid) do
    %{
      pool_name: pool_name,
      worker_id: worker_id,
      pool_state: pool_state,
      new_queue: new_queue,
      pruned_cancelled: pruned_cancelled,
      state: state
    } = ctx

    SLog.debug(@log_category, "Discarding request from dead client #{inspect(client_pid)}")
    GenServer.cast(self(), {:checkin_worker, pool_name, worker_id, :skip_decrement})

    updated_pool_state = %{
      pool_state
      | request_queue: new_queue,
        cancelled_requests: pruned_cancelled
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    {:noreply, %{state | pools: updated_pools}}
  end

  defp handle_worker_down(worker_id, pid, reason, state) do
    SLog.error(
      @log_category,
      "Worker #{worker_id} (pid: #{inspect(pid)}) died: #{inspect(reason)}"
    )

    :ets.match_delete(state.affinity_cache, {:_, worker_id, :_})

    pool_name = extract_pool_name_from_worker_id(worker_id)

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

  defp remove_worker_from_pool(state, pool_name, pool_state, worker_id) do
    new_workers = List.delete(pool_state.workers, worker_id)
    new_available = MapSet.delete(pool_state.available, worker_id)
    new_loads = Map.delete(pool_state.worker_loads, worker_id)
    new_capacities = Map.delete(pool_state.worker_capacities, worker_id)

    updated_pool_state = %{
      pool_state
      | workers: new_workers,
        available: new_available,
        worker_loads: new_loads,
        worker_capacities: new_capacities
    }

    updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
    %{state | pools: updated_pools}
  end

  @impl true
  def terminate(reason, state) do
    SLog.info(@log_category, "🛑 Pool manager terminating with reason: #{inspect(reason)}.")

    # Log state of pools during shutdown (debug level)
    Enum.each(state.pools, fn {pool_name, pool_state} ->
      SLog.debug(@log_category, """
      Pool #{pool_name} shutdown state:
        Initialized: #{pool_state.initialized}
        Workers: #{length(pool_state.workers)}
        Available: #{MapSet.size(pool_state.available)}
        Busy: #{busy_worker_count(pool_state)}
        Queued: #{:queue.len(pool_state.request_queue)}
        Waiters: #{length(pool_state.initialization_waiters)}
      """)

      if not Enum.empty?(pool_state.initialization_waiters) do
        SLog.warning(
          @log_category,
          "Pool #{pool_name}: #{length(pool_state.initialization_waiters)} processes still waiting for pool init!"
        )
      end
    end)

    # Supervision tree will handle worker shutdown via WorkerSupervisor
    :ok
  end

  # REMOVE the wait_for_ports_to_exit/2 helper functions.

  # Private Functions
  defp resolve_pool_configs do
    case Config.get_pool_configs() do
      {:ok, configs} when is_list(configs) and configs != [] ->
        SLog.info(@log_category, "Initializing #{length(configs)} pool(s)")
        {:ok, configs}

      {:ok, []} ->
        SLog.warning(@log_category, "No pool configs found, using legacy defaults")
        {:ok, [%{name: :default}]}

      {:error, reason} ->
        SLog.error(@log_category, "Pool configuration error: #{inspect(reason)}")
        {:error, {:invalid_pool_config, reason}}
    end
  end

  defp checkout_worker(pool_state, session_id, affinity_cache) do
    case try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
      {:ok, worker_id, new_state} ->
        {:ok, worker_id, new_state}

      :no_preferred_worker ->
        case next_available_worker(pool_state) do
          {:ok, worker_id} ->
            new_pool_state = State.increment_worker_load(pool_state, worker_id)
            maybe_track_capacity(new_pool_state, worker_id, :increment)
            maybe_store_session_affinity(session_id, worker_id)
            {:ok, worker_id, new_pool_state}

          :no_workers ->
            {:error, :no_workers}
        end
    end
  end

  defp try_checkout_preferred_worker(_pool_state, nil, _affinity_cache), do: :no_preferred_worker

  defp try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
    # PERFORMANCE FIX: Use shared affinity_cache from top-level state
    case get_preferred_worker(session_id, affinity_cache) do
      {:ok, preferred_worker_id} ->
        # Check if preferred worker is available and not tainted
        if MapSet.member?(pool_state.available, preferred_worker_id) and
             not CrashBarrier.worker_tainted?(preferred_worker_id) do
          new_pool_state = State.increment_worker_load(pool_state, preferred_worker_id)
          maybe_track_capacity(new_pool_state, preferred_worker_id, :increment)
          maybe_store_session_affinity(session_id, preferred_worker_id)

          SLog.debug(
            @log_category,
            "Using preferred worker #{preferred_worker_id} for session #{session_id}"
          )

          {:ok, preferred_worker_id, new_pool_state}
        else
          :no_preferred_worker
        end

      {:error, :not_found} ->
        :no_preferred_worker
    end
  end

  defp next_available_worker(pool_state) do
    pool_state.available
    |> Enum.find(fn worker_id -> not CrashBarrier.worker_tainted?(worker_id) end)
    |> case do
      nil -> :no_workers
      worker_id -> {:ok, worker_id}
    end
  end

  defp select_queue_worker(pool_state, worker_id) do
    if CrashBarrier.worker_tainted?(worker_id) do
      case next_available_worker(pool_state) do
        {:ok, available} -> {:ok, available}
        :no_workers -> :no_worker
      end
    else
      {:ok, worker_id}
    end
  end

  defp busy_worker_count(pool_state) do
    map_size(pool_state.worker_loads)
  end

  defp maybe_track_capacity(pool_state, worker_id, :increment) do
    if should_track_capacity?(pool_state) do
      track_capacity_increment(worker_id)
    end
  end

  defp maybe_track_capacity(pool_state, worker_id, :decrement) do
    if pool_state.capacity_strategy == :hybrid and
         Config.thread_profile?(pool_state.pool_config) do
      case Snakepit.Pool.Registry.get_worker_pid(worker_id) do
        {:ok, pid} ->
          _ = CapacityStore.decrement_load(pid)

        {:error, _} ->
          :ok
      end
    end
  end

  defp should_track_capacity?(pool_state) do
    pool_state.capacity_strategy == :hybrid and Config.thread_profile?(pool_state.pool_config)
  end

  defp track_capacity_increment(worker_id) do
    _ = CapacityStore.ensure_started()

    with {:ok, pid} <- Snakepit.Pool.Registry.get_worker_pid(worker_id),
         result <- CapacityStore.check_and_increment_load(pid) do
      handle_capacity_increment_result(result, pid)
    else
      {:error, _} -> :ok
    end
  end

  defp handle_capacity_increment_result({:ok, capacity, new_load}, pid) do
    if new_load == capacity do
      emit_capacity_reached_telemetry(capacity, new_load, pid, false)
    end
  end

  defp handle_capacity_increment_result({:at_capacity, capacity, load}, pid) do
    emit_capacity_reached_telemetry(capacity, load, pid, true)
  end

  defp handle_capacity_increment_result({:error, :unknown_worker}, pid) do
    SLog.warning(@log_category, "Worker #{inspect(pid)} not found in capacity store")
  end

  defp emit_capacity_reached_telemetry(capacity, load, pid, rejected?) do
    metadata = %{worker_pid: pid, profile: :thread}
    metadata = if rejected?, do: Map.put(metadata, :rejected, true), else: metadata

    :telemetry.execute(
      [:snakepit, :pool, :capacity_reached],
      %{capacity: capacity, load: load},
      metadata
    )
  end

  # PERFORMANCE FIX: ETS-cached session affinity lookup
  # Eliminates GenServer bottleneck by caching session->worker mappings with TTL
  defp get_preferred_worker(session_id, cache_table) do
    current_time = System.monotonic_time(:second)

    case lookup_cached_worker(cache_table, session_id, current_time) do
      {:ok, worker_id} ->
        {:ok, worker_id}

      :cache_miss ->
        fetch_and_cache_worker(session_id, cache_table, current_time)
    end
  end

  defp lookup_cached_worker(cache_table, session_id, current_time) do
    case :ets.lookup(cache_table, session_id) do
      [{^session_id, worker_id, expires_at}] when expires_at > current_time ->
        {:ok, worker_id}

      _ ->
        :cache_miss
    end
  end

  defp fetch_and_cache_worker(session_id, cache_table, current_time) do
    case SessionStore.get_session(session_id) do
      {:ok, session} ->
        extract_and_cache_worker_id(session, session_id, cache_table, current_time)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp extract_and_cache_worker_id(session, session_id, cache_table, current_time) do
    case Map.get(session, :last_worker_id) do
      nil ->
        {:error, :not_found}

      worker_id ->
        expires_at = current_time + 60
        :ets.insert(cache_table, {session_id, worker_id, expires_at})
        {:ok, worker_id}
    end
  end

  defp maybe_store_session_affinity(nil, _worker_id), do: :ok

  defp maybe_store_session_affinity(session_id, worker_id) do
    store_session_affinity(session_id, worker_id)
  end

  defp store_session_affinity(session_id, worker_id) do
    # Store the worker affinity in a supervised task for better error logging
    async_with_context(fn ->
      :ok = SessionStore.store_worker_session(session_id, worker_id)
      SLog.debug(@log_category, "Stored session affinity: #{session_id} -> #{worker_id}")
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
          LifecycleManager.increment_request_count(worker_id)

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

  defp execute_with_crash_barrier(
         pool_pid,
         pool_name,
         worker_id,
         command,
         args,
         opts,
         pool_config
       ) do
    crash_config = CrashBarrier.config(pool_config)

    if CrashBarrier.enabled?(crash_config) do
      attempt_with_retry(pool_pid, pool_name, worker_id, command, args, opts, crash_config, 0)
    else
      {execute_on_worker(worker_id, command, args, opts), worker_id}
    end
  end

  defp attempt_with_retry(
         pool_pid,
         pool_name,
         worker_id,
         command,
         args,
         opts,
         crash_config,
         attempt
       ) do
    result = execute_on_worker(worker_id, command, args, opts)

    retry_context = %{
      pool_pid: pool_pid,
      pool_name: pool_name,
      command: command,
      args: args,
      opts: opts,
      crash_config: crash_config
    }

    case CrashBarrier.crash_info(result, crash_config) do
      {:ok, info} ->
        maybe_taint_worker(pool_name, worker_id, info, crash_config)

        handle_crash_retry(result, info, retry_context, attempt)

      :error ->
        {result, worker_id}
    end
  end

  defp maybe_taint_worker(pool_name, worker_id, info, crash_config) do
    if CrashBarrier.worker_tainted?(worker_id) do
      :ok
    else
      CrashBarrier.taint_worker(pool_name, worker_id, info, crash_config)
    end
  end

  defp handle_crash_retry(result, info, retry_context, attempt) do
    if CrashBarrier.retry_allowed?(
         retry_context.crash_config,
         CrashBarrier.idempotent?(retry_context.args),
         attempt
       ) do
      maybe_wait_backoff(CrashBarrier.retry_backoff(retry_context.crash_config, attempt + 1))

      retry_with_worker(result, info, retry_context, attempt)
    else
      {CrashBarrier.normalize_crash_error(result, info), nil}
    end
  end

  defp retry_with_worker(result, info, retry_context, attempt) do
    case checkout_worker_for_retry(
           retry_context.pool_pid,
           retry_context.pool_name,
           retry_context.args,
           retry_context.opts
         ) do
      {:ok, next_worker} ->
        attempt_with_retry(
          retry_context.pool_pid,
          retry_context.pool_name,
          next_worker,
          retry_context.command,
          retry_context.args,
          retry_context.opts,
          retry_context.crash_config,
          attempt + 1
        )

      {:error, _reason} ->
        {CrashBarrier.normalize_crash_error(result, info), nil}
    end
  end

  defp checkout_worker_for_retry(pool_pid, pool_name, args, opts) do
    session_id =
      opts[:session_id] ||
        Map.get(args, :session_id) ||
        Map.get(args, "session_id")

    GenServer.call(
      pool_pid,
      {:checkout_worker, pool_name, session_id},
      Defaults.crash_barrier_checkout_timeout()
    )
  end

  defp maybe_wait_backoff(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    receive do
    after
      delay_ms -> :ok
    end
  end

  defp maybe_wait_backoff(_), do: :ok

  defp get_worker_module(worker_id) do
    # Try to determine the worker module from registry or configuration
    case PoolRegistry.fetch_worker(worker_id) do
      {:ok, _pid, %{worker_module: module}} when is_atom(module) ->
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
          nil -> Defaults.default_command_timeout()
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

  defp monitor_client_status(ref, client_pid) do
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

  defp async_with_context(fun) when is_function(fun, 0) do
    ctx = :otel_ctx.get_current()

    Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
      token = :otel_ctx.attach(ctx)

      try do
        fun.()
      after
        :otel_ctx.detach(token)
      end
    end)
  end

  @doc false
  def extract_pool_name_from_worker_id(worker_id) do
    case lookup_pool_from_registry(worker_id) do
      {:ok, pool_name} ->
        pool_name

      {:error, reason} ->
        inferred = infer_pool_from_id(worker_id)

        SLog.warning(
          @log_category,
          "Falling back to worker_id parsing for #{worker_id}: #{inspect(reason)}. Using #{inspect(inferred)}"
        )

        inferred
    end
  end

  defp lookup_pool_from_registry(worker_id) do
    case PoolRegistry.fetch_worker(worker_id) do
      {:ok, pid, metadata} ->
        extract_pool_from_metadata(metadata, pid)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :registry_lookup_failed}
  end

  defp extract_pool_from_metadata(metadata, pid) do
    case Map.get(metadata, :pool_identifier) do
      pool_identifier when is_atom(pool_identifier) and not is_nil(pool_identifier) ->
        {:ok, pool_identifier}

      _ ->
        extract_pool_from_name(metadata, pid)
    end
  end

  defp extract_pool_from_name(metadata, pid) do
    pool_name = Map.get(metadata, :pool_name)
    extract_pool_name_by_type(pool_name, metadata, pid)
  end

  defp extract_pool_name_by_type(pool_name, _metadata, _pid) when is_atom(pool_name) do
    validate_atom_pool_name(pool_name)
  end

  defp extract_pool_name_by_type(pool_pid, _metadata, _pid) when is_pid(pool_pid) do
    extract_pool_name_from_pid(pool_pid)
  end

  defp extract_pool_name_by_type(pool_name, _metadata, _pid) when is_binary(pool_name) do
    convert_string_to_pool_name(pool_name)
  end

  defp extract_pool_name_by_type(nil, metadata, pid) do
    {:error, {:pool_metadata_missing, %{metadata_keys: Map.keys(metadata), worker_pid: pid}}}
  end

  defp validate_atom_pool_name(pool_name) do
    if module_atom?(pool_name) do
      {:error, {:pool_metadata_module_atom, pool_name}}
    else
      {:ok, pool_name}
    end
  end

  defp extract_pool_name_from_pid(pool_pid) do
    case Process.info(pool_pid, :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        {:ok, name}

      _ ->
        {:error, {:pool_metadata_not_atom, pool_pid}}
    end
  end

  defp convert_string_to_pool_name(pool_name) do
    atom_name = String.to_existing_atom(pool_name)
    validate_atom_pool_name(atom_name)
  rescue
    ArgumentError -> {:error, {:pool_metadata_not_atom, pool_name}}
  end

  defp module_atom?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.starts_with?("Elixir.")
  end

  defp infer_pool_from_id(worker_id) do
    case String.split(worker_id, "_worker_", parts: 2) do
      [pool_name_str, _rest] ->
        safe_to_existing_atom(pool_name_str)

      _ ->
        :default
    end
  end

  defp safe_to_existing_atom(pool_name_str) do
    String.to_existing_atom(pool_name_str)
  rescue
    ArgumentError -> :default
  end
end
