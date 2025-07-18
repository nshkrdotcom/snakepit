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
    :max_queue_size
    # Note: process_pids removed - ProcessRegistry is the single source of truth
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

    state = %__MODULE__{
      size: size,
      workers: [],
      available: :queue.new(),
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
      max_queue_size: max_queue_size
    }

    # Start concurrent worker initialization
    {:ok, state, {:continue, :initialize_workers}}
  end

  @impl true
  def handle_continue(:initialize_workers, state) do
    Logger.info("🚀 Starting concurrent initialization of #{state.size} workers...")
    start_time = System.monotonic_time(:millisecond)

    # Start all workers concurrently
    workers = start_workers_concurrently(state.size, state.startup_timeout)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("✅ Initialized #{length(workers)}/#{state.size} workers in #{elapsed}ms")

    if length(workers) == 0 do
      {:stop, :no_workers_started, state}
    else
      # Initialize available queue with all workers
      available =
        Enum.reduce(workers, :queue.new(), fn worker_id, q ->
          :queue.in(worker_id, q)
        end)

      {:noreply, %{state | workers: workers, available: available, initialized: true}}
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
                Logger.warning("Client #{inspect(client_pid)} died before receiving reply. Checking in worker #{worker_id}.")
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

  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        workers: length(state.workers),
        available: :queue.len(state.available),
        busy: map_size(state.busy),
        queued: :queue.len(state.request_queue)
      })

    {:reply, stats, state}
  end

  def handle_call(:list_workers, _from, state) do
    {:reply, state.workers, state}
  end

  @impl true
  def handle_cast({:checkin_worker, worker_id}, state) do
    # Check for queued requests first
    case :queue.out(state.request_queue) do
      {{:value, {queued_from, command, args, opts, _queued_at}}, new_queue} ->
        # A request was waiting! Give it the worker immediately
        Task.Supervisor.async_nolink(Snakepit.TaskSupervisor, fn ->
          result = execute_on_worker(worker_id, command, args, opts)
          GenServer.reply(queued_from, result)
          GenServer.cast(__MODULE__, {:checkin_worker, worker_id})
        end)

        {:noreply, %{state | request_queue: new_queue}}

      {:empty, _} ->
        # No requests waiting, return worker to available queue
        new_available = :queue.in(worker_id, state.available)
        new_busy = Map.delete(state.busy, worker_id)
        {:noreply, %{state | available: new_available, busy: new_busy}}
    end
  end

  @impl true
  def handle_info({:queue_timeout, from}, state) do
    # Remove request from queue if still there
    new_queue =
      :queue.filter(
        fn
          {^from, _, _, _, _} -> false
          _ -> true
        end,
        state.request_queue
      )

    # Reply with timeout error if request was still queued
    if :queue.len(new_queue) < :queue.len(state.request_queue) do
      GenServer.reply(from, {:error, :queue_timeout})

      stats = Map.update!(state.stats, :queue_timeouts, &(&1 + 1))
      {:noreply, %{state | request_queue: new_queue, stats: stats}}
    else
      # Request already processed
      {:noreply, state}
    end
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

  def handle_info(msg, state) do
    Logger.debug("Pool received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warning(
      "🛑 Pool is terminating with reason: #{inspect(reason)}. Shutting down workers gracefully."
    )

    # Get all worker PIDs supervised by our supervisor
    worker_pids = Snakepit.Pool.WorkerSupervisor.list_workers()

    Logger.warning("🔄 Requesting graceful shutdown of #{length(worker_pids)} workers...")

    # Tell the supervisor to terminate each child gracefully
    # This is a synchronous operation for each worker
    terminated_count =
      Enum.reduce(worker_pids, 0, fn pid, acc ->
        Logger.debug("Pool requesting shutdown of worker #{inspect(pid)}")

        case DynamicSupervisor.terminate_child(Snakepit.Pool.WorkerSupervisor, pid) do
          :ok ->
            acc + 1

          {:error, :not_found} ->
            # Worker already terminated
            acc + 1
        end
      end)

    Logger.warning("✅ Pool shutdown complete. #{terminated_count} workers terminated gracefully.")
    :ok
  end

  # Private Functions

  defp start_workers_concurrently(count, startup_timeout) do
    1..count
    |> Task.async_stream(
      fn i ->
        worker_id = "pool_worker_#{i}_#{:erlang.unique_integer([:positive])}"

        case Snakepit.Pool.WorkerSupervisor.start_worker(worker_id) do
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
        case :queue.out(state.available) do
          {{:value, worker_id}, new_available} ->
            new_busy = Map.put(state.busy, worker_id, true)
            new_state = %{state | available: new_available, busy: new_busy}
            
            # Store session affinity if we have a session_id
            if session_id do
              store_session_affinity(session_id, worker_id)
            end
            
            {:ok, worker_id, new_state}

          {:empty, _} ->
            {:error, :no_workers}
        end
    end
  end
  
  defp try_checkout_preferred_worker(_state, nil), do: :no_preferred_worker
  
  defp try_checkout_preferred_worker(state, session_id) do
    case get_preferred_worker(session_id) do
      {:ok, preferred_worker_id} ->
        # Check if the preferred worker is available
        if queue_contains?(state.available, preferred_worker_id) do
          # Remove the preferred worker from available queue
          new_available = queue_remove(state.available, preferred_worker_id)
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
    # Store the worker affinity asynchronously to avoid blocking
    Task.start(fn ->
      Snakepit.Bridge.SessionStore.store_worker_session(session_id, worker_id)
    end)
  end
  
  defp queue_contains?(queue, item) do
    :queue.to_list(queue) |> Enum.member?(item)
  end
  
  defp queue_remove(queue, item) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == item))
    |> :queue.from_list()
  end

  defp execute_on_worker(worker_id, command, args, opts) do
    timeout = get_command_timeout(command, args, opts)

    try do
      Snakepit.Pool.Worker.execute(worker_id, command, args, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error, :worker_timeout}

      :exit, reason ->
        {:error, {:worker_exit, reason}}
    end
  end

  defp get_command_timeout(command, args, opts) do
    # Prefer explicit client timeout, then adapter timeout, then global default
    case opts[:timeout] do
      nil ->
        case get_adapter_timeout(command, args) do
          nil -> 30_000  # Global default
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
            _ -> nil  # Fall back to default if adapter timeout fails
          end
        else
          nil
        end
    end
  end
end
