defmodule Snakepit.WorkerProfile.Thread do
  @moduledoc """
  Multi-threaded worker profile (Python 3.13+ optimized).

  Each worker is a Python process with a thread pool, providing:
  - **Shared memory**: Zero-copy data sharing within worker
  - **CPU parallelism**: True multi-threading without GIL (Python 3.13+)
  - **Lower memory**: One interpreter vs many
  - **High throughput**: Optimal for CPU-bound tasks

  ## Configuration

      config :snakepit,
        pools: [
          %{
            name: :hpc_pool,
            worker_profile: :thread,
            pool_size: 4,                    # 4 processes
            threads_per_worker: 16,          # 16 threads each = 64 total capacity
            adapter_module: Snakepit.Adapters.GRPCPython,
            adapter_args: ["--mode", "threaded", "--max-workers", "16"],
            adapter_env: [
              # Allow multi-threading in libraries
              {"OPENBLAS_NUM_THREADS", "16"},
              {"OMP_NUM_THREADS", "16"}
            ],
            worker_ttl: {3600, :seconds},    # Recycle hourly
            worker_max_requests: 1000,       # Or after 1000 requests
            thread_safety_checks: true       # Enable runtime validation
          }
        ]

  ## Requirements

  - Python 3.13+ for optimal performance (free-threading)
  - Thread-safe Python adapters
  - Thread-safe ML libraries (NumPy, PyTorch, etc.)

  ## Status

  Thread profile is fully supported when paired with Python 3.13+ and thread-safe adapters.

  ## Implementation Notes

  The thread profile:
  1. Starts fewer Python processes (4-16 instead of 100+)
  2. Runs a ThreadPoolExecutor per worker process
  3. Tracks per-worker capacity via `threads_per_worker` for pool scheduling
  4. Supports optional CapacityStore telemetry with `capacity_strategy: :hybrid`
  5. Allows concurrent requests to the same worker via HTTP/2 multiplexing
  """

  @behaviour Snakepit.WorkerProfile

  require Logger
  alias Snakepit.Logger, as: SLog
  alias Snakepit.Logger.Redaction
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.WorkerProfile.Thread.CapacityStore

  @impl true
  def start_worker(config) do
    worker_id = Map.fetch!(config, :worker_id)
    worker_module = Map.get(config, :worker_module, Snakepit.GRPCWorker)
    adapter_module = Map.fetch!(config, :adapter_module)
    pool_name = Map.get(config, :pool_name, Snakepit.Pool)
    threads_per_worker = Map.get(config, :threads_per_worker, 10)

    # Ensure capacity tracking table exists
    ensure_capacity_table()

    # Build adapter args and env for threaded mode
    adapter_args = build_adapter_args(config)
    adapter_env = build_adapter_env(config)

    SLog.info("Starting threaded worker #{worker_id} with #{threads_per_worker} threads")
    SLog.debug("Thread worker adapter_args: #{Redaction.describe(adapter_args)}")

    # Create enhanced worker config with thread profile settings
    worker_config =
      config
      |> Map.put(:adapter_args, adapter_args)
      |> Map.put(:adapter_env, adapter_env)

    # Start the worker via WorkerSupervisor with full config
    case WorkerSupervisor.start_worker(
           worker_id,
           worker_module,
           adapter_module,
           pool_name,
           worker_config
         ) do
      {:ok, pid} ->
        :ok = CapacityStore.track_worker(pid, threads_per_worker)

        SLog.info(
          "Thread profile started worker #{worker_id}: #{inspect(pid)} with capacity #{threads_per_worker}"
        )

        {:ok, pid}

      error ->
        SLog.error("Failed to start threaded worker #{worker_id}: #{inspect(error)}")
        error
    end
  end

  @impl true
  def stop_worker(worker_pid) when is_pid(worker_pid) do
    # Remove from capacity table
    ensure_capacity_table()
    :ok = CapacityStore.untrack_worker(worker_pid)

    case PoolRegistry.get_worker_id_by_pid(worker_pid) do
      {:ok, worker_id} ->
        case WorkerSupervisor.stop_worker(worker_id) do
          {:error, :worker_not_found} -> :ok
          other -> other
        end

      {:error, :not_found} ->
        # Worker not found, may already be stopped
        :ok
    end
  end

  def stop_worker(worker_id) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} -> stop_worker(pid)
      {:error, :not_found} -> :ok
    end
  end

  @impl true
  def execute_request(worker_pid, request, timeout) when is_pid(worker_pid) do
    # Check capacity before executing
    case check_and_increment_load(worker_pid) do
      :ok ->
        command = Map.fetch!(request, :command)
        args = Map.get(request, :args, %{})

        # Execute via worker module
        worker_module = get_worker_module(worker_pid)

        try do
          result = worker_module.execute(worker_pid, command, args, timeout)
          result
        after
          # Always decrement load, even on error
          decrement_load(worker_pid)
        end

      {:error, :at_capacity} ->
        {:error, :worker_at_capacity}
    end
  end

  def execute_request(worker_id, request, timeout) when is_binary(worker_id) do
    # Lookup PID from worker_id
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        execute_request(pid, request, timeout)

      {:error, _} ->
        {:error, :worker_not_found}
    end
  end

  @impl true
  def get_capacity(worker_pid) when is_pid(worker_pid) do
    ensure_capacity_table()
    CapacityStore.get_capacity(worker_pid)
  end

  def get_capacity(worker_id) when is_atom(worker_id) do
    # Handle atom input (for tests)
    1
  end

  def get_capacity(worker_id) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} -> get_capacity(pid)
      {:error, _} -> 1
    end
  end

  @impl true
  def get_load(worker_pid) when is_pid(worker_pid) do
    ensure_capacity_table()
    CapacityStore.get_load(worker_pid)
  end

  def get_load(worker_id) when is_atom(worker_id) do
    # Handle atom input (for tests with :fake_worker, etc.)
    0
  end

  def get_load(worker_id) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} -> get_load(pid)
      {:error, _} -> 0
    end
  end

  @impl true
  def health_check(worker_handle) when is_pid(worker_handle) do
    if Process.alive?(worker_handle) do
      # Optionally could send a ping command
      :ok
    else
      {:error, :worker_dead}
    end
  end

  def health_check(worker_id) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        health_check(pid)

      {:error, _} ->
        {:error, :worker_not_found}
    end
  end

  @impl true
  def get_metadata(worker_pid) when is_pid(worker_pid) do
    capacity = get_capacity(worker_pid)
    load = get_load(worker_pid)

    {:ok,
     %{
       profile: :thread,
       capacity: capacity,
       load: load,
       available_capacity: capacity - load,
       worker_type: "multi-threaded",
       threading: "thread-pool"
     }}
  end

  def get_metadata(worker_id) when is_atom(worker_id) do
    # Handle atom input (for tests with :fake_worker, etc.)
    {:ok,
     %{
       profile: :thread,
       capacity: 1,
       load: 0,
       available_capacity: 1,
       worker_type: "multi-threaded",
       threading: "thread-pool"
     }}
  end

  def get_metadata(worker_id) when is_binary(worker_id) do
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        capacity = get_capacity(pid)
        load = get_load(pid)

        {:ok,
         %{
           profile: :thread,
           capacity: capacity,
           load: load,
           available_capacity: capacity - load,
           worker_type: "multi-threaded",
           threading: "thread-pool",
           worker_id: worker_id
         }}

      {:error, _} ->
        {:error, :worker_not_found}
    end
  end

  # Private helpers

  defp ensure_capacity_table do
    case CapacityStore.ensure_started() do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        SLog.warning("Capacity store failed to start: #{inspect(reason)}")
        :ok
    end
  end

  defp build_adapter_args(config) do
    threads = Map.get(config, :threads_per_worker, 10)
    adapter_spec = get_adapter_spec(config)
    thread_safety_checks = Map.get(config, :thread_safety_checks, false)

    # Base args for threaded mode
    base_args = [
      "--adapter",
      adapter_spec,
      "--max-workers",
      "#{threads}"
    ]

    # Add thread safety checking if enabled
    base_args =
      if thread_safety_checks do
        base_args ++ ["--thread-safety-check"]
      else
        base_args
      end

    # Merge with user-provided args
    user_args = Map.get(config, :adapter_args, [])

    # User args can override base args
    merge_args(base_args, user_args)
  end

  defp get_adapter_spec(config) do
    # Try multiple sources for adapter spec
    Map.get(config, :adapter_spec) ||
      extract_adapter_from_args(Map.get(config, :adapter_args, [])) ||
      "snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter"
  end

  defp extract_adapter_from_args(args) do
    # Look for --adapter flag in user args
    case Enum.find_index(args, &(&1 == "--adapter")) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp merge_args(base_args, user_args) do
    # Simple merge: user args override base args
    # For more sophisticated merging, could parse flags
    (user_args ++ base_args)
    |> Enum.chunk_every(2)
    |> Enum.uniq_by(fn
      [flag, _] -> flag
      [flag] -> flag
    end)
    |> List.flatten()
  end

  defp build_adapter_env(config) do
    threads = Map.get(config, :threads_per_worker, 10)

    # Default env for threaded mode (allow multi-threading)
    default_env = [
      {"OPENBLAS_NUM_THREADS", "#{threads}"},
      {"OMP_NUM_THREADS", "#{threads}"},
      {"MKL_NUM_THREADS", "#{threads}"},
      {"NUMEXPR_NUM_THREADS", "#{threads}"}
    ]

    # Get user-specified environment (overrides defaults)
    user_env = Map.get(config, :adapter_env, [])

    # User env takes precedence
    merged =
      Enum.reduce(user_env, Map.new(default_env), fn {key, val}, acc ->
        Map.put(acc, key, val)
      end)

    Map.to_list(merged)
  end

  defp check_and_increment_load(worker_pid) do
    ensure_capacity_table()

    case CapacityStore.check_and_increment_load(worker_pid) do
      {:ok, capacity, new_load} ->
        if new_load == capacity do
          :telemetry.execute(
            [:snakepit, :pool, :capacity_reached],
            %{capacity: capacity, load: new_load},
            %{worker_pid: worker_pid, profile: :thread}
          )
        end

        :ok

      {:at_capacity, capacity, load} ->
        :telemetry.execute(
          [:snakepit, :pool, :capacity_reached],
          %{capacity: capacity, load: load},
          %{worker_pid: worker_pid, profile: :thread, rejected: true}
        )

        {:error, :at_capacity}

      {:error, :unknown_worker} ->
        SLog.warning("Worker #{inspect(worker_pid)} not found in capacity store")
        :ok
    end
  end

  defp decrement_load(worker_pid) do
    ensure_capacity_table()
    CapacityStore.decrement_load(worker_pid)
  end

  defp get_worker_module(worker_pid) do
    with {:ok, worker_id} <-
           Snakepit.Pool.Registry.get_worker_id_by_pid(worker_pid),
         {:ok, _pid, %{worker_module: module}} <-
           PoolRegistry.fetch_worker(worker_id) do
      module
    else
      _ ->
        # Default to GRPCWorker
        Snakepit.GRPCWorker
    end
  end
end
