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
  alias Snakepit.Pool.Dispatcher
  alias Snakepit.Pool.EventHandler
  alias Snakepit.Pool.Initializer
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.State
  alias Snakepit.Pool.Worker.StarterRegistry
  alias Snakepit.Shutdown
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
    init_start_time: nil,
    # Timestamp for measuring initialization duration
    init_task_ref: nil,
    # Monitor ref for async pool initialization task
    init_task_pid: nil,
    # PID for async pool initialization task (for shutdown cancellation)
    init_resource_baseline: nil,
    # Baseline resource snapshot captured at init start
    async_task_refs: MapSet.new(),
    # Task refs started via Task.Supervisor.async_nolink for fire-and-forget work
    reconcile_ref: nil,
    # Periodic pool reconciliation timer reference
    await_ready_waiters: [],
    # Waiters for global await_ready/2 calls
    init_complete_waiters: []
    # Waiters for await_init_complete/2 calls
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

    {call_timeout, opts_with_deadline} =
      case timeout do
        :infinity ->
          {:infinity, opts}

        timeout_ms when is_integer(timeout_ms) ->
          deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
          {timeout_ms, Keyword.put(opts, :deadline_ms, deadline_ms)}
      end

    try do
      GenServer.call(pool, {:execute, command, args, opts_with_deadline}, call_timeout)
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
            execute_on_worker_stream(worker_id, command, args, callback_fn, timeout, opts)
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
    GenServer.call(pool, {:checkout_worker, opts[:session_id], opts}, timeout)
  end

  defp checkin_worker(pool, worker_id) do
    GenServer.cast(pool, {:checkin_worker, worker_id})
  end

  defp execute_on_worker_stream(worker_id, command, args, callback_fn, timeout, opts) do
    worker_module = get_worker_module(worker_id)
    SLog.debug(@log_category, "[Pool] execute_on_worker_stream using #{inspect(worker_module)}")

    if function_exported?(worker_module, :execute_stream, 5) do
      SLog.debug(
        @log_category,
        "[Pool] Invoking #{worker_module}.execute_stream with timeout #{timeout}"
      )

      result =
        worker_module.execute_stream(
          worker_id,
          command,
          args,
          callback_fn,
          Keyword.put(opts, :timeout, timeout)
        )

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

  defp emit_init_complete_telemetry(pool_worker_counts, total_workers, elapsed_ms) do
    :telemetry.execute(
      [:snakepit, :pool, :init_complete],
      %{duration_ms: elapsed_ms, total_workers: total_workers, count: 1},
      %{pool_workers: pool_worker_counts}
    )
  end

  defp emit_worker_ready_telemetry(pool_name, worker_id, pool_state) do
    :telemetry.execute(
      [:snakepit, :pool, :worker_ready],
      %{worker_count: length(pool_state.workers), count: 1},
      %{pool_name: pool_name, worker_id: worker_id}
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
  Waits for the pool to be ready for service.

  Returns `:ok` when each pool has at least one ready worker, or
  `{:error, %Snakepit.Error{}}` if any pool fails to start workers or the
  timeout is exceeded.
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

  @doc """
  Waits for asynchronous pool initialization to complete.

  Returns `:ok` when the pool has finished its initialization phase, or
  `{:error, %Snakepit.Error{}}` if any pool fails to start workers or the
  timeout is exceeded.
  """
  @spec await_init_complete(atom() | pid(), timeout() | nil) :: :ok | {:error, Error.t()}
  def await_init_complete(pool \\ __MODULE__, timeout \\ nil)

  def await_init_complete(pool, nil),
    do: await_init_complete(pool, Defaults.pool_await_ready_timeout())

  def await_init_complete(pool, timeout) do
    GenServer.call(pool, :await_init_complete, timeout)
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
    multi_pool_mode? = Config.multi_pool_mode?()

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

  # Handle completion of async pool initialization task
  @impl true
  def handle_info({ref, {:pool_init_complete, updated_pools}}, %{init_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    elapsed = System.monotonic_time(:millisecond) - (state.init_start_time || 0)

    # DIAGNOSTIC: Capture peak system resource usage after startup
    peak_resources = Initializer.capture_resource_metrics()
    baseline_resources = state.init_resource_baseline || peak_resources
    resource_delta = Initializer.calculate_resource_delta(baseline_resources, peak_resources)

    pool_worker_counts =
      Enum.into(updated_pools, %{}, fn {name, pool} -> {name, length(pool.workers)} end)

    total_workers =
      Enum.reduce(pool_worker_counts, 0, fn {_name, count}, acc -> acc + count end)

    emit_init_complete_telemetry(pool_worker_counts, total_workers, elapsed)

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
      merged_pools = merge_initialized_pools(state.pools, updated_pools)

      reconcile_ref = schedule_reconcile(Defaults.pool_reconcile_interval_ms())

      new_state =
        %{
          state
          | pools: merged_pools,
            initializing: false,
            init_start_time: nil,
            reconcile_ref: reconcile_ref
        }
        |> clear_init_task_state()

      {:noreply, maybe_reply_waiters(new_state)}
    else
      SLog.error(
        @log_category,
        "❌ All configured pools failed to start workers (#{Enum.map_join(failed_pool_names, ", ", &to_string/1)})."
      )

      error = await_ready_error(failed_pool_names)
      reply_waiters_now(state.init_complete_waiters, {:error, error})

      {:stop, :no_workers_started,
       state
       |> Map.put(:init_complete_waiters, [])
       |> clear_init_task_state()}
    end
  end

  # Handle async initialization task failures during startup.
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{initializing: true, init_task_ref: ref} = state
      ) do
    case reason do
      :normal ->
        # Result message may still be in flight; wait for `{ref, {:pool_init_complete, ...}}`
        # before clearing init task tracking.
        {:noreply, state}

      :shutdown ->
        # Clean shutdown - supervisor is terminating
        SLog.info(@log_category, "Pool initialization interrupted by shutdown")

        {:stop, :shutdown, clear_init_task_state(state)}

      {:shutdown, _} ->
        # Clean shutdown with reason
        SLog.info(@log_category, "Pool initialization interrupted by shutdown")

        {:stop, :shutdown, clear_init_task_state(state)}

      :killed ->
        # Init process was killed (e.g., supervisor timeout)
        SLog.warning(@log_category, "Pool initialization process killed")

        {:stop, :killed, clear_init_task_state(state)}

      other ->
        # Init process crashed
        SLog.error(@log_category, "Pool initialization failed: #{inspect(other)}")

        {:stop, {:init_failed, other}, clear_init_task_state(state)}
    end
  end

  # queue_timeout - WITH pool_name
  def handle_info({:queue_timeout, pool_name, from}, state) do
    EventHandler.handle_queue_timeout(state, pool_name, from)
  end

  # Legacy queue_timeout WITHOUT pool_name
  def handle_info({:queue_timeout, from}, state) do
    handle_info({:queue_timeout, state.default_pool, from}, state)
  end

  # Worker death - find which pool it belongs to
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      ref == state.init_task_ref ->
        {:noreply, clear_init_task_state(state)}

      true ->
        EventHandler.handle_down(state, pid, reason)
    end
  end

  def handle_info({:track_async_task_ref, _ref}, state) do
    # Backward compatibility: older async helpers may still send this message.
    # We no longer track task refs asynchronously to avoid late-track races.
    {:noreply, state}
  end

  def handle_info({:reply_to_waiter, from, reply}, state) do
    # PERFORMANCE FIX: Staggered reply to avoid thundering herd
    GenServer.reply(from, reply)
    {:noreply, state}
  end

  def handle_info({:reply_to_waiter, from}, state) do
    # Backward-compat for older scheduled replies
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_info(:reconcile_pools, state) do
    new_state = maybe_reconcile_pools(state)
    reconcile_ref = schedule_reconcile(Defaults.pool_reconcile_interval_ms())
    {:noreply, %{new_state | reconcile_ref: reconcile_ref}}
  end

  @doc false
  # Backward compatibility: ignore legacy completion messages from fire-and-forget tasks.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(msg, state) do
    SLog.debug(@log_category, "Pool received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:execute, command, args, opts}, from, state) do
    # Backward compatibility: route to default pool
    pool_name = resolve_pool_name_opt(opts, state.default_pool)
    Dispatcher.execute(state, pool_name, command, args, opts, from, dispatcher_context())
  end

  def handle_call({:execute, pool_name, command, args, opts}, from, state) do
    Dispatcher.execute(state, pool_name, command, args, opts, from, dispatcher_context())
  end

  def handle_call({:checkout_worker, session_id}, _from, state) do
    handle_checkout_worker_call(state, state.default_pool, session_id, [])
  end

  def handle_call({:checkout_worker, session_id, opts}, _from, state)
      when is_list(opts) or is_map(opts) do
    pool_name = resolve_pool_name_opt(opts, state.default_pool)
    handle_checkout_worker_call(state, pool_name, session_id, opts)
  end

  def handle_call({:checkout_worker, pool_name, session_id}, _from, state)
      when is_atom(pool_name) do
    handle_checkout_worker_call(state, pool_name, session_id, [])
  end

  def handle_call({:checkout_worker, pool_name, session_id, opts}, _from, state)
      when is_atom(pool_name) do
    handle_checkout_worker_call(state, pool_name, session_id, opts)
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
    failed_pools = failed_pool_names(state.pools)

    cond do
      failed_pools != [] ->
        {:reply, {:error, await_ready_error(failed_pools)}, state}

      all_pools_initialized?(state.pools) ->
        {:reply, :ok, state}

      true ->
        {:noreply, %{state | await_ready_waiters: [from | state.await_ready_waiters]}}
    end
  end

  def handle_call(:await_init_complete, from, state) do
    failed_pools = failed_pool_names(state.pools)

    cond do
      state.initializing == false and failed_pools == [] ->
        {:reply, :ok, state}

      state.initializing == false ->
        {:reply, {:error, await_ready_error(failed_pools)}, state}

      true ->
        {:noreply, %{state | init_complete_waiters: [from | state.init_complete_waiters]}}
    end
  end

  def handle_call({:await_ready, pool_name}, from, state) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        cond do
          Map.get(pool_state, :init_failed, false) ->
            {:reply, {:error, await_ready_error([pool_name])}, state}

          pool_ready?(pool_state) ->
            {:reply, :ok, state}

          true ->
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
    case mark_worker_ready(state, worker_id) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  defp mark_worker_ready(state, worker_id) do
    SLog.info(@log_category, "Worker #{worker_id} reported ready. Processing queued work.")

    # Find which pool this worker belongs to by worker_id prefix
    pool_name = extract_pool_name_from_worker_id(worker_id)

    case Map.get(state.pools, pool_name) do
      nil ->
        SLog.error(
          @log_category,
          "Worker #{worker_id} reported ready but pool #{pool_name} not found!"
        )

        {:error, :pool_not_found, state}

      pool_state ->
        # Ensure worker is in workers list
        new_workers =
          if Enum.member?(pool_state.workers, worker_id) do
            pool_state.workers
          else
            [worker_id | pool_state.workers]
          end

        ready_workers = Map.get(pool_state, :ready_workers) || MapSet.new()

        updated_pool_state =
          pool_state
          |> Map.put(:ready_workers, MapSet.put(ready_workers, worker_id))
          |> Map.put(:workers, new_workers)
          |> State.ensure_worker_capacity(worker_id)
          |> State.ensure_worker_available(worker_id)
          |> Map.put(:initialized, true)
          |> Map.put(:init_failed, false)

        emit_worker_ready_telemetry(pool_name, worker_id, updated_pool_state)

        # CRITICAL FIX: Immediately drive the queue by treating this as a checkin
        GenServer.cast(self(), {:checkin_worker, pool_name, worker_id, :skip_decrement})

        CrashBarrier.maybe_emit_restart(pool_name, worker_id)

        updated_pools = Map.put(state.pools, pool_name, updated_pool_state)
        {:ok, maybe_reply_waiters(%{state | pools: updated_pools})}
    end
  end

  defp all_pools_initialized?(pools) do
    Enum.all?(pools, fn {_name, pool} -> pool_ready?(pool) end)
  end

  defp pool_ready?(pool_state) do
    ready_workers = Map.get(pool_state, :ready_workers) || MapSet.new()
    MapSet.size(ready_workers) > 0
  end

  defp failed_pool_names(pools) do
    pools
    |> Enum.filter(fn {_name, pool} -> Map.get(pool, :init_failed, false) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp await_ready_error([pool_name]) do
    Error.pool_error("Pool failed to start workers", %{pool: pool_name})
  end

  defp await_ready_error(pool_names) do
    Error.pool_error("Pools failed to start workers", %{pools: pool_names})
  end

  defp merge_initialized_pools(current_pools, updated_pools) do
    Enum.reduce(updated_pools, current_pools, fn {name, updated_pool}, acc ->
      current_pool = Map.get(acc, name, updated_pool)
      Map.put(acc, name, merge_pool_state(current_pool, updated_pool))
    end)
  end

  defp merge_pool_state(current_pool, updated_pool) do
    workers = Enum.uniq(updated_pool.workers ++ current_pool.workers)
    ready_workers = Map.get(current_pool, :ready_workers) || MapSet.new()
    ready_workers = MapSet.intersection(ready_workers, MapSet.new(workers))

    capacity_seed =
      Map.merge(current_pool.worker_capacities, updated_pool.worker_capacities)

    worker_capacities =
      State.build_worker_capacities(%{current_pool | worker_capacities: capacity_seed}, workers)

    available = MapSet.intersection(current_pool.available, ready_workers)

    initialized =
      current_pool.initialized || not Enum.empty?(workers)

    init_failed = Map.get(updated_pool, :init_failed, false)

    %{
      current_pool
      | size: updated_pool.size,
        pool_config: updated_pool.pool_config,
        worker_module: updated_pool.worker_module,
        adapter_module: updated_pool.adapter_module,
        capacity_strategy: updated_pool.capacity_strategy,
        startup_timeout: updated_pool.startup_timeout,
        queue_timeout: updated_pool.queue_timeout,
        max_queue_size: updated_pool.max_queue_size,
        workers: workers,
        worker_capacities: worker_capacities,
        available: available,
        ready_workers: ready_workers,
        initialized: initialized,
        init_failed: init_failed
    }
  end

  defp maybe_reply_waiters(state) do
    state
    |> maybe_reply_pool_waiters()
    |> maybe_reply_global_waiters()
    |> maybe_reply_init_complete_waiters()
  end

  defp maybe_reply_pool_waiters(state) do
    {pools, waiters} =
      Enum.map_reduce(state.pools, [], fn {name, pool}, acc ->
        cond do
          Map.get(pool, :init_failed, false) and pool.initialization_waiters != [] ->
            error = await_ready_error([name])

            waiters_with_reply =
              Enum.map(pool.initialization_waiters, fn waiter ->
                {:reply, waiter, {:error, error}}
              end)

            {{name, %{pool | initialization_waiters: []}}, acc ++ waiters_with_reply}

          pool_ready?(pool) and pool.initialization_waiters != [] ->
            {{name, %{pool | initialization_waiters: []}}, acc ++ pool.initialization_waiters}

          true ->
            {{name, pool}, acc}
        end
      end)

    schedule_waiter_replies(waiters)
    %{state | pools: Enum.into(pools, %{})}
  end

  defp maybe_reply_global_waiters(state) do
    if state.await_ready_waiters != [] do
      failed_pools = failed_pool_names(state.pools)

      cond do
        failed_pools != [] ->
          schedule_waiter_replies(
            state.await_ready_waiters,
            {:error, await_ready_error(failed_pools)}
          )

          %{state | await_ready_waiters: []}

        all_pools_initialized?(state.pools) ->
          schedule_waiter_replies(state.await_ready_waiters)
          %{state | await_ready_waiters: []}

        true ->
          state
      end
    else
      state
    end
  end

  defp maybe_reply_init_complete_waiters(%{init_complete_waiters: []} = state), do: state

  defp maybe_reply_init_complete_waiters(%{initializing: true} = state), do: state

  defp maybe_reply_init_complete_waiters(state) do
    failed_pools = failed_pool_names(state.pools)

    reply =
      if failed_pools == [] do
        :ok
      else
        {:error, await_ready_error(failed_pools)}
      end

    schedule_waiter_replies(state.init_complete_waiters, reply)
    %{state | init_complete_waiters: []}
  end

  defp schedule_waiter_replies([]), do: :ok

  defp schedule_waiter_replies(waiters, reply \\ :ok) do
    waiters
    |> Enum.map(fn
      {:reply, from, custom_reply} -> {from, custom_reply}
      from -> {from, reply}
    end)
    |> Enum.with_index()
    |> Enum.each(fn {{from, reply_value}, index} ->
      Process.send_after(self(), {:reply_to_waiter, from, reply_value}, index * 2)
    end)
  end

  defp reply_waiters_now([], _reply), do: :ok

  defp reply_waiters_now(waiters, reply) do
    waiters
    |> Enum.map(fn
      {:reply, from, custom_reply} -> {from, custom_reply}
      from -> {from, reply}
    end)
    |> Enum.each(fn {from, reply_value} ->
      GenServer.reply(from, reply_value)
    end)
  end

  defp schedule_reconcile(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :reconcile_pools, interval_ms)
  end

  defp schedule_reconcile(_interval_ms), do: nil

  defp maybe_reconcile_pools(%{initializing: true} = state), do: state

  defp maybe_reconcile_pools(state) do
    if Shutdown.in_progress?() do
      state
    else
      reconcile_pools(state)
    end
  end

  defp reconcile_pools(state) do
    if supervisor_alive?() do
      Enum.each(state.pools, fn {pool_name, pool_state} ->
        maybe_spawn_replacements(pool_name, pool_state)
      end)
    end

    state
  end

  defp maybe_spawn_replacements(pool_name, pool_state) do
    desired = desired_worker_count(pool_state)
    starter_count = starter_count_for_pool(pool_name)
    deficit = max(desired - starter_count, 0)

    if deficit > 0 do
      spawn_count = min(deficit, Defaults.pool_reconcile_batch_size())
      spawn_replacement_workers(pool_name, pool_state, spawn_count)
    end
  end

  defp starter_count_for_pool(pool_name) do
    prefix = "#{pool_name}_worker_"

    StarterRegistry.list_starters()
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  defp spawn_replacement_workers(_pool_name, _pool_state, count) when count <= 0, do: :ok

  defp spawn_replacement_workers(pool_name, pool_state, count) do
    Enum.each(1..count, fn _ ->
      start_replacement_worker(pool_name, pool_state)
    end)
  end

  defp start_replacement_worker(pool_name, pool_state) do
    worker_id =
      "#{pool_name}_worker_#{:erlang.unique_integer([:positive, :monotonic])}"

    if Map.has_key?(pool_state.pool_config, :worker_profile) do
      profile_module = Config.get_profile_module(pool_state.pool_config)

      worker_config =
        pool_state.pool_config
        |> Map.put(:worker_id, worker_id)
        |> Map.put(:worker_module, pool_state.worker_module)
        |> Map.put(:adapter_module, pool_state.adapter_module)
        |> Map.put(:pool_name, self())
        |> Map.put(:pool_identifier, pool_name)

      _ = profile_module.start_worker(worker_config)
    else
      _ =
        Snakepit.Pool.WorkerSupervisor.start_worker(
          worker_id,
          pool_state.worker_module,
          pool_state.adapter_module,
          self(),
          %{pool_identifier: pool_name}
        )
    end
  end

  defp desired_worker_count(pool_state) do
    max_workers = Config.pool_max_workers(pool_state.pool_config)
    min(pool_state.size, max_workers)
  end

  @spec supervisor_alive?() :: boolean()
  defp supervisor_alive? do
    case Process.whereis(Snakepit.Pool.WorkerSupervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp dispatcher_context do
    %{
      checkout_worker: &checkout_worker/4,
      execute_with_crash_barrier: &execute_with_crash_barrier/7,
      async_with_context: &async_with_context/1,
      maybe_checkin_worker: &maybe_checkin_worker/2
    }
  end

  defp event_handler_context do
    %{
      async_with_context: &async_with_context/1,
      execute_with_crash_barrier: &execute_with_crash_barrier/7,
      maybe_checkin_worker: &maybe_checkin_worker/2,
      maybe_track_capacity: &maybe_track_capacity/3,
      select_queue_worker: &select_queue_worker/2
    }
  end

  defp maybe_checkin_worker(_pool_name, nil), do: :ok

  defp maybe_checkin_worker(pool_name, worker_id) do
    GenServer.cast(__MODULE__, {:checkin_worker, pool_name, worker_id})
  end

  def handle_cast({:worker_ready, worker_id}, state) do
    case mark_worker_ready(state, worker_id) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  # checkin_worker - WITH pool_name parameter
  @impl true
  def handle_cast({:checkin_worker, pool_name, worker_id, :skip_decrement}, state)
      when is_atom(pool_name) do
    EventHandler.handle_checkin(state, pool_name, worker_id, false, event_handler_context())
  end

  def handle_cast({:checkin_worker, pool_name, worker_id}, state) when is_atom(pool_name) do
    EventHandler.handle_checkin(state, pool_name, worker_id, true, event_handler_context())
  end

  # Legacy checkin_worker WITHOUT pool_name (infer from worker_id)
  def handle_cast({:checkin_worker, worker_id}, state) do
    pool_name = extract_pool_name_from_worker_id(worker_id)
    handle_cast({:checkin_worker, pool_name, worker_id}, state)
  end

  @impl true
  def terminate(reason, state) do
    SLog.info(@log_category, "🛑 Pool manager terminating with reason: #{inspect(reason)}.")
    maybe_stop_init_task(state)

    # Log state of pools during shutdown (debug level)
    Enum.each(state.pools, fn {pool_name, pool_state} ->
      SLog.debug(@log_category, """
      Pool #{pool_name} shutdown state:
        Initialized: #{pool_state.initialized}
        Workers: #{length(pool_state.workers)}
        Ready: #{MapSet.size(pool_state.ready_workers)}
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

  defp maybe_stop_init_task(%{init_task_ref: ref, init_task_pid: pid})
       when is_reference(ref) and is_pid(pid) do
    Process.demonitor(ref, [:flush])

    maybe_exit_process(pid, :shutdown)

    :ok
  end

  defp maybe_stop_init_task(_state), do: :ok

  defp maybe_exit_process(pid, reason) when is_pid(pid) do
    Process.exit(pid, reason)
    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, _ -> :ok
  end

  defp clear_init_task_state(state) do
    %{state | init_task_ref: nil, init_task_pid: nil, init_resource_baseline: nil}
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

  defp checkout_worker(pool_state, session_id, affinity_cache, opts) do
    affinity_mode = resolve_affinity_mode(pool_state, opts)

    case try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
      {:ok, worker_id, new_state} ->
        {:ok, worker_id, new_state}

      {:unavailable, preferred_worker_id, :busy} ->
        handle_preferred_busy(pool_state, session_id, affinity_mode, preferred_worker_id)

      {:unavailable, preferred_worker_id, reason} ->
        handle_preferred_unavailable(
          pool_state,
          session_id,
          affinity_mode,
          preferred_worker_id,
          reason
        )

      :no_preferred_worker ->
        checkout_any_available(pool_state, session_id)
    end
  end

  defp handle_preferred_busy(pool_state, session_id, :hint, _preferred_worker_id) do
    checkout_any_available(pool_state, session_id)
  end

  defp handle_preferred_busy(_pool_state, _session_id, :strict_queue, preferred_worker_id) do
    {:error, {:affinity_busy, preferred_worker_id}}
  end

  defp handle_preferred_busy(_pool_state, _session_id, :strict_fail_fast, _preferred_worker_id) do
    {:error, :worker_busy}
  end

  defp handle_preferred_unavailable(pool_state, session_id, :hint, _preferred_worker_id, _reason) do
    checkout_any_available(pool_state, session_id)
  end

  defp handle_preferred_unavailable(
         _pool_state,
         _session_id,
         _affinity_mode,
         _preferred_worker_id,
         _reason
       ) do
    {:error, :session_worker_unavailable}
  end

  defp checkout_any_available(pool_state, session_id) do
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

  defp try_checkout_preferred_worker(_pool_state, nil, _affinity_cache), do: :no_preferred_worker

  defp try_checkout_preferred_worker(pool_state, session_id, affinity_cache) do
    # PERFORMANCE FIX: Use shared affinity_cache from top-level state
    case get_preferred_worker(session_id, affinity_cache) do
      {:ok, preferred_worker_id} ->
        preferred_worker_status(pool_state, preferred_worker_id)
        |> handle_preferred_status(pool_state, session_id, preferred_worker_id)

      {:error, :not_found} ->
        :no_preferred_worker
    end
  end

  defp handle_preferred_status(:available, pool_state, session_id, preferred_worker_id) do
    new_pool_state = State.increment_worker_load(pool_state, preferred_worker_id)
    maybe_track_capacity(new_pool_state, preferred_worker_id, :increment)
    maybe_store_session_affinity(session_id, preferred_worker_id)

    SLog.debug(
      @log_category,
      "Using preferred worker #{preferred_worker_id} for session #{session_id}"
    )

    {:ok, preferred_worker_id, new_pool_state}
  end

  defp handle_preferred_status(status, _pool_state, _session_id, preferred_worker_id) do
    {:unavailable, preferred_worker_id, status}
  end

  defp preferred_worker_status(pool_state, preferred_worker_id) do
    cond do
      CrashBarrier.worker_tainted?(preferred_worker_id) ->
        :tainted

      not Enum.member?(pool_state.workers, preferred_worker_id) ->
        :missing

      MapSet.member?(pool_state.available, preferred_worker_id) ->
        :available

      true ->
        :busy
    end
  end

  defp resolve_affinity_mode(pool_state, opts) do
    mode =
      fetch_affinity_opt(opts) ||
        Map.get(pool_state.pool_config || %{}, :affinity) ||
        Defaults.default_affinity_mode()

    normalize_affinity_mode(mode)
  end

  defp fetch_affinity_opt(opts) when is_list(opts), do: Keyword.get(opts, :affinity)

  defp fetch_affinity_opt(opts) when is_map(opts) do
    Map.get(opts, :affinity) || Map.get(opts, "affinity")
  end

  defp fetch_affinity_opt(_opts), do: nil

  defp resolve_pool_name_opt(opts, default_pool) do
    case fetch_pool_name_opt(opts) do
      nil ->
        default_pool

      name when is_atom(name) ->
        name

      name when is_binary(name) ->
        case convert_string_to_pool_name(name) do
          {:ok, atom_name} -> atom_name
          {:error, _} -> default_pool
        end

      _ ->
        default_pool
    end
  end

  defp fetch_pool_name_opt(opts) when is_list(opts), do: Keyword.get(opts, :pool_name)

  defp fetch_pool_name_opt(opts) when is_map(opts) do
    Map.get(opts, :pool_name) || Map.get(opts, "pool_name")
  end

  defp fetch_pool_name_opt(_opts), do: nil

  defp normalize_affinity_mode(mode) when mode in [:hint, :strict_queue, :strict_fail_fast],
    do: mode

  defp normalize_affinity_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "hint" -> :hint
      "strict_queue" -> :strict_queue
      "strict_fail_fast" -> :strict_fail_fast
      _ -> Defaults.default_affinity_mode()
    end
  end

  defp normalize_affinity_mode(_mode), do: Defaults.default_affinity_mode()

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
          case CapacityStore.ensure_started() do
            {:ok, store_pid} -> _ = CapacityStore.decrement_load(store_pid, pid)
            {:error, _reason} -> :ok
          end

        {:error, _} ->
          :ok
      end
    end
  end

  defp should_track_capacity?(pool_state) do
    pool_state.capacity_strategy == :hybrid and Config.thread_profile?(pool_state.pool_config)
  end

  defp track_capacity_increment(worker_id) do
    case CapacityStore.ensure_started() do
      {:ok, store_pid} ->
        with {:ok, pid} <- Snakepit.Pool.Registry.get_worker_pid(worker_id),
             result <- CapacityStore.check_and_increment_load(store_pid, pid) do
          handle_capacity_increment_result(result, pid)
        else
          {:error, _} -> :ok
        end

      {:error, _reason} ->
        :ok
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
        expires_at = current_time + Defaults.affinity_cache_ttl_seconds()
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
      case SessionStore.store_worker_session(session_id, worker_id) do
        :ok ->
          SLog.debug(@log_category, "Stored session affinity: #{session_id} -> #{worker_id}")

        {:error, reason} ->
          SLog.warning(
            @log_category,
            "Failed to store session affinity #{session_id} -> #{worker_id}: #{inspect(reason)}"
          )
      end

      :ok
    end)
  end

  defp execute_on_worker(worker_id, command, args, opts) do
    timeout = get_command_timeout(worker_id, command, args, opts)
    worker_module = get_worker_module(worker_id)

    try do
      result =
        worker_module.execute(
          worker_id,
          command,
          args,
          normalize_worker_execute_opts(opts, timeout)
        )

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
      {:checkout_worker, pool_name, session_id, opts},
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

  defp get_command_timeout(worker_id, command, args, opts) do
    # Prefer explicit client timeout, then adapter timeout, then global default
    case opts[:timeout] do
      nil ->
        case get_adapter_timeout(worker_id, command, args) do
          # Global default
          nil -> Defaults.default_command_timeout()
          adapter_timeout -> adapter_timeout
        end

      client_timeout ->
        client_timeout
    end
  end

  defp get_adapter_timeout(worker_id, command, args) do
    adapter_module =
      case PoolRegistry.fetch_worker(worker_id) do
        {:ok, _pid, metadata} ->
          Config.adapter_module(%{}, override: Map.get(metadata, :adapter_module))

        _ ->
          Config.adapter_module()
      end

    resolve_adapter_timeout(adapter_module, command, args)
  end

  defp resolve_adapter_timeout(nil, _command, _args), do: nil

  defp resolve_adapter_timeout(adapter_module, command, args) do
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

  defp normalize_worker_execute_opts(opts, timeout) when is_list(opts) do
    Keyword.put(opts, :timeout, timeout)
  end

  defp normalize_worker_execute_opts(opts, timeout) when is_map(opts) do
    Enum.reduce(opts, [timeout: timeout], fn
      {key, value}, acc when is_atom(key) ->
        Keyword.put(acc, key, value)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_worker_execute_opts(_opts, timeout), do: [timeout: timeout]

  defp async_with_context(fun) when is_function(fun, 0) do
    ctx = :otel_ctx.get_current()

    runner = fn ->
      token = :otel_ctx.attach(ctx)

      try do
        fun.()
      after
        :otel_ctx.detach(token)
      end
    end

    try do
      _ = Task.Supervisor.start_child(Snakepit.TaskSupervisor, runner)
      :ok
    rescue
      error ->
        SLog.warning(
          @log_category,
          "TaskSupervisor unavailable for pool async task; using monitored fallback",
          error: error
        )

        _ = spawn_monitor(fn -> runner.() end)
        :ok
    catch
      :exit, reason ->
        SLog.warning(
          @log_category,
          "TaskSupervisor exited for pool async task; using monitored fallback",
          reason: reason
        )

        _ = spawn_monitor(fn -> runner.() end)
        :ok
    end
  end

  defp handle_checkout_worker_call(state, pool_name, session_id, opts) do
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool_state ->
        case checkout_worker(pool_state, session_id, state.affinity_cache, opts) do
          {:ok, worker_id, new_pool_state} ->
            updated_pools = Map.put(state.pools, pool_name, new_pool_state)
            {:reply, {:ok, worker_id}, %{state | pools: updated_pools}}

          {:error, reason} ->
            {:reply, normalize_checkout_error(reason), state}
        end
    end
  end

  defp normalize_checkout_error(:no_workers), do: {:error, :no_workers_available}

  defp normalize_checkout_error({:affinity_busy, _preferred_worker_id}),
    do: {:error, :worker_busy}

  defp normalize_checkout_error(:worker_busy), do: {:error, :worker_busy}

  defp normalize_checkout_error(:session_worker_unavailable),
    do: {:error, :session_worker_unavailable}

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
    cond do
      pool_name == Snakepit.Pool ->
        {:ok, :default}

      module_atom?(pool_name) ->
        {:error, {:pool_metadata_module_atom, pool_name}}

      true ->
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
