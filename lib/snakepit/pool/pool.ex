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

  @default_size System.schedulers_online() * 2
  @default_startup_timeout 10_000
  @default_queue_timeout 5_000
  @default_max_queue_size 1000

  defstruct [
    :size,
    :workers,
    :available,
    :busy,
    :request_queue,
    :stats,
    :initialized,
    :startup_timeout,
    :queue_timeout,
    :max_queue_size,
    :worker_module,
    :adapter_module,
    # Note: process_pids removed - ProcessRegistry is the single source of truth
    initialization_waiters: []
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
    Logger.info("[Pool] execute_stream called for command: #{command}, args: #{inspect(args)}")

    case checkout_worker_for_stream(pool, opts) do
      {:ok, worker_id} ->
        Logger.info("[Pool] Checked out worker: #{worker_id}")

        result = execute_on_worker_stream(worker_id, command, args, callback_fn, timeout)

        # Always check the worker back in after streaming completes
        checkin_worker(pool, worker_id)

        case result do
          :ok ->
            Logger.info("[Pool] Stream completed successfully")
            :ok

          {:error, reason} ->
            Logger.error("[Pool] Stream failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[Pool] Failed to checkout worker: #{inspect(reason)}")
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
    Logger.info("[Pool] execute_on_worker_stream - worker_module: #{inspect(worker_module)}")

    if function_exported?(worker_module, :execute_stream, 5) do
      Logger.info("[Pool] Calling #{worker_module}.execute_stream with timeout: #{timeout}")
      result = worker_module.execute_stream(worker_id, command, args, callback_fn, timeout)
      Logger.info("[Pool] execute_stream returned: #{inspect(result)}")
      result
    else
      Logger.error("[Pool] Worker module #{worker_module} does not export execute_stream/5")
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
  """
  def list_workers(pool \\ __MODULE__) do
    GenServer.call(pool, :list_workers)
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

    size = opts[:size] || @default_size

    startup_timeout =
      Application.get_env(:snakepit, :pool_startup_timeout, @default_startup_timeout)

    queue_timeout = Application.get_env(:snakepit, :pool_queue_timeout, @default_queue_timeout)
    max_queue_size = Application.get_env(:snakepit, :pool_max_queue_size, @default_max_queue_size)

    worker_module = opts[:worker_module] || Snakepit.GRPCWorker
    adapter_module = opts[:adapter_module] || Application.get_env(:snakepit, :adapter_module)

    state = %__MODULE__{
      size: size,
      workers: [],
      available: MapSet.new(),
      busy: %{},
      request_queue: :queue.new(),
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
      adapter_module: adapter_module
    }

    # Start concurrent worker initialization
    {:ok, state, {:continue, :initialize_workers}}
  end

  @impl true
  def handle_continue(:initialize_workers, state) do
    Logger.info("🚀 Starting concurrent initialization of #{state.size} workers...")
    start_time = System.monotonic_time(:millisecond)

    # Start all workers concurrently
    workers =
      start_workers_concurrently(
        state.size,
        state.startup_timeout,
        state.worker_module,
        state.adapter_module
      )

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("✅ Initialized #{length(workers)}/#{state.size} workers in #{elapsed}ms")

    if length(workers) == 0 do
      {:stop, :no_workers_started, state}
    else
      # Initialize available set with all workers
      available = MapSet.new(workers)
      new_state = %{state | workers: workers, available: available, initialized: true}

      # Reply to all waiting callers
      for from <- state.initialization_waiters do
        GenServer.reply(from, :ok)
      end

      {:noreply, %{new_state | initialization_waiters: []}}
    end
  end

  @impl true
  def handle_call({:execute, command, args, opts}, from, state) do
    if not state.initialized do
      {:reply, {:error, :pool_not_initialized}, state}
    else
      session_id = opts[:session_id]

      case checkout_worker(state, session_id) do
        {:ok, worker_id, new_state} ->
          # Execute in a supervised, unlinked task
          Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
            # Extract the actual PID from the from tuple for monitoring
            {client_pid, _tag} = from
            ref = Process.monitor(client_pid)
            result = execute_on_worker(worker_id, command, args, opts)

            # Check if the client is still alive
            receive do
              {:DOWN, ^ref, :process, ^client_pid, _reason} ->
                # Client is dead, don't try to reply. Just check in the worker.
                Logger.warning(
                  "Client #{inspect(client_pid)} died before receiving reply. Checking in worker #{worker_id}."
                )

                GenServer.cast(__MODULE__, {:checkin_worker, worker_id})
            after
              0 ->
                # Client is alive. Clean up the monitor and proceed.
                Process.demonitor(ref, [:flush])
                GenServer.reply(from, result)
                GenServer.cast(__MODULE__, {:checkin_worker, worker_id})
            end
          end)

          # Update stats
          stats = Map.update!(state.stats, :requests, &(&1 + 1))
          # We reply :noreply immediately, the task will reply to the caller later
          {:noreply, %{new_state | stats: stats}}

        {:error, :no_workers} ->
          # Check if queue is at max capacity
          current_queue_size = :queue.len(state.request_queue)

          if current_queue_size >= state.max_queue_size do
            # Pool is saturated, reject request immediately
            stats = Map.update!(state.stats, :pool_saturated, &(&1 + 1))
            {:reply, {:error, :pool_saturated}, %{state | stats: stats}}
          else
            # Queue the request
            request = {from, command, args, opts, System.monotonic_time()}
            new_queue = :queue.in(request, state.request_queue)

            # Update stats
            stats =
              state.stats
              |> Map.update!(:requests, &(&1 + 1))
              |> Map.update!(:queued, &(&1 + 1))

            # Set queue timeout
            Process.send_after(self(), {:queue_timeout, from}, state.queue_timeout)

            {:noreply, %{state | request_queue: new_queue, stats: stats}}
          end
      end
    end
  end

  def handle_call({:checkout_worker, session_id}, _from, state) do
    case checkout_worker(state, session_id) do
      {:ok, worker_id, new_state} ->
        {:reply, {:ok, worker_id}, new_state}

      {:error, :no_workers} ->
        {:reply, {:error, :no_workers_available}, state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        workers: length(state.workers),
        available: MapSet.size(state.available),
        busy: map_size(state.busy),
        queued: :queue.len(state.request_queue)
      })

    {:reply, stats, state}
  end

  def handle_call(:list_workers, _from, state) do
    {:reply, state.workers, state}
  end

  @impl true
  def handle_call(:await_ready, from, state) do
    if state.initialized do
      {:reply, :ok, state}
    else
      # Pool is not ready yet, queue the caller to be replied to later
      new_waiters = [from | state.initialization_waiters]
      {:noreply, %{state | initialization_waiters: new_waiters}}
    end
  end

  @impl true
  def handle_cast({:worker_ready, worker_id}, state) do
    Logger.info("Worker #{worker_id} reported ready, adding back to pool.")

    new_workers =
      if Enum.member?(state.workers, worker_id) do
        state.workers
      else
        [worker_id | state.workers]
      end

    new_available = MapSet.put(state.available, worker_id)
    {:noreply, %{state | workers: new_workers, available: new_available}}
  end

  def handle_cast({:checkin_worker, worker_id}, state) do
    # Check for queued requests first
    case :queue.out(state.request_queue) do
      {{:value, {queued_from, command, args, opts, _queued_at}}, new_queue} ->
        # Check if the queued client is still alive before processing
        {client_pid, _tag} = queued_from

        if Process.alive?(client_pid) do
          # Client is alive, process the request normally
          Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
            ref = Process.monitor(client_pid)
            result = execute_on_worker(worker_id, command, args, opts)

            # Check if the client is still alive after execution
            receive do
              {:DOWN, ^ref, :process, ^client_pid, _reason} ->
                # Client died during execution, don't try to reply
                Logger.warning(
                  "Queued client #{inspect(client_pid)} died during execution. Checking in worker #{worker_id}."
                )

                GenServer.cast(__MODULE__, {:checkin_worker, worker_id})
            after
              0 ->
                # Client is alive, clean up monitor and reply
                Process.demonitor(ref, [:flush])
                GenServer.reply(queued_from, result)
                GenServer.cast(__MODULE__, {:checkin_worker, worker_id})
            end
          end)

          {:noreply, %{state | request_queue: new_queue}}
        else
          # Client is dead, discard request and check for the next one
          Logger.debug("Discarding request from dead client #{inspect(client_pid)}")
          GenServer.cast(self(), {:checkin_worker, worker_id})
          {:noreply, %{state | request_queue: new_queue}}
        end

      {:empty, _} ->
        # No requests waiting, return worker to available set
        new_available = MapSet.put(state.available, worker_id)
        new_busy = Map.delete(state.busy, worker_id)
        {:noreply, %{state | available: new_available, busy: new_busy}}
    end
  end

  @impl true
  def handle_info({:queue_timeout, from}, state) do
    # Since dead clients are now handled efficiently during dequeue,
    # we only need to reply with timeout error. The queue filtering is
    # handled naturally during normal processing via Process.alive? checks.
    GenServer.reply(from, {:error, :queue_timeout})

    stats = Map.update!(state.stats, :queue_timeouts, &(&1 + 1))
    {:noreply, %{state | stats: stats}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # O(1) lookup of worker_id by PID using Registry
    case Snakepit.Pool.Registry.get_worker_id_by_pid(pid) do
      {:error, :not_found} ->
        # Not a worker we are tracking, ignore
        {:noreply, state}

      {:ok, worker_id} ->
        Logger.error("Worker #{worker_id} (pid: #{inspect(pid)}) died: #{inspect(reason)}")

        # Just remove the dead worker from the pool's state
        # The Worker.Starter will automatically restart it via supervisor tree
        # The new worker will re-register itself when ready
        new_workers = List.delete(state.workers, worker_id)
        new_available = :queue.filter(&(&1 != worker_id), state.available)
        new_busy = Map.delete(state.busy, worker_id)

        Logger.debug(
          "Pool updated state after worker death. Worker.Starter will handle restart automatically."
        )

        {:noreply, %{state | workers: new_workers, available: new_available, busy: new_busy}}
    end
  end

  @doc false
  # Handles completion messages from tasks started via Task.Supervisor.async_nolink.
  # These are used for fire-and-forget operations (like replying to callers or
  # kicking off worker respawns), so we can safely ignore the completion message.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Pool received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # REPLACED: Go back to a simple, non-orchestrating terminate.
  # The supervisor will handle shutting down the WorkerSupervisor, which cascades.
  @impl true
  def terminate(reason, _state) do
    Logger.info("🛑 Pool manager terminating with reason: #{inspect(reason)}.")
    :ok
  end

  # REMOVE the wait_for_ports_to_exit/2 helper functions.

  # Private Functions

  defp start_workers_concurrently(count, startup_timeout, worker_module, adapter_module) do
    Logger.info("🚀 Starting concurrent initialization of #{count} workers...")
    Logger.info("📦 Using worker type: #{inspect(worker_module)}")

    1..count
    |> Task.async_stream(
      fn i ->
        worker_id = "pool_worker_#{i}_#{:erlang.unique_integer([:positive])}"

        case Snakepit.Pool.WorkerSupervisor.start_worker(worker_id, worker_module, adapter_module) do
          {:ok, _pid} ->
            Logger.info("✅ Worker #{i}/#{count} ready: #{worker_id}")
            worker_id

          {:error, reason} ->
            Logger.error("❌ Worker #{i}/#{count} failed: #{inspect(reason)}")
            nil
        end
      end,
      timeout: startup_timeout,
      max_concurrency: count,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, worker_id} ->
        worker_id

      {:exit, reason} ->
        Logger.error("Worker startup task failed: #{inspect(reason)}")
        nil
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp checkout_worker(state, session_id) do
    case try_checkout_preferred_worker(state, session_id) do
      {:ok, worker_id, new_state} ->
        {:ok, worker_id, new_state}

      :no_preferred_worker ->
        # Fall back to any available worker
        case Enum.take(state.available, 1) do
          [worker_id] ->
            new_available = MapSet.delete(state.available, worker_id)
            new_busy = Map.put(state.busy, worker_id, true)
            new_state = %{state | available: new_available, busy: new_busy}

            # Store session affinity if we have a session_id
            if session_id do
              store_session_affinity(session_id, worker_id)
            end

            {:ok, worker_id, new_state}

          [] ->
            {:error, :no_workers}
        end
    end
  end

  defp try_checkout_preferred_worker(_state, nil), do: :no_preferred_worker

  defp try_checkout_preferred_worker(state, session_id) do
    case get_preferred_worker(session_id) do
      {:ok, preferred_worker_id} ->
        # Check if the preferred worker is available
        if MapSet.member?(state.available, preferred_worker_id) do
          # Remove the preferred worker from available set
          new_available = MapSet.delete(state.available, preferred_worker_id)
          new_busy = Map.put(state.busy, preferred_worker_id, true)
          new_state = %{state | available: new_available, busy: new_busy}

          Logger.debug("Using preferred worker #{preferred_worker_id} for session #{session_id}")
          {:ok, preferred_worker_id, new_state}
        else
          :no_preferred_worker
        end

      {:error, :not_found} ->
        :no_preferred_worker
    end
  end

  defp get_preferred_worker(session_id) do
    case Snakepit.Bridge.SessionStore.get_session(session_id) do
      {:ok, session} ->
        case Map.get(session, :last_worker_id) do
          nil -> {:error, :not_found}
          worker_id -> {:ok, worker_id}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp store_session_affinity(session_id, worker_id) do
    # Store the worker affinity in a supervised task for better error logging
    Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
      :ok = Snakepit.Bridge.SessionStore.store_worker_session(session_id, worker_id)
      Logger.debug("Stored session affinity: #{session_id} -> #{worker_id}")
      :ok
    end)
  end

  defp execute_on_worker(worker_id, command, args, opts) do
    timeout = get_command_timeout(command, args, opts)
    worker_module = get_worker_module(worker_id)

    try do
      worker_module.execute(worker_id, command, args, timeout)
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
end
