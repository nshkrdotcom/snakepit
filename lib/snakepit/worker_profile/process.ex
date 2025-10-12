defmodule Snakepit.WorkerProfile.Process do
  @moduledoc """
  Multi-process worker profile (default).

  Each worker is a separate OS process, providing:
  - **Process isolation**: Crashes don't affect other workers
  - **GIL compatibility**: Works with all Python versions
  - **High concurrency**: Optimal for 100+ workers with I/O-bound tasks

  This is the default profile and maintains 100% backward compatibility
  with Snakepit v0.5.x configurations.

  ## Configuration

      config :snakepit,
        pools: [
          %{
            name: :default,
            worker_profile: :process,  # Explicit (or omit for default)
            pool_size: 100,
            adapter_module: Snakepit.Adapters.GRPCPython,
            adapter_env: [
              {"OPENBLAS_NUM_THREADS", "1"},
              {"OMP_NUM_THREADS", "1"}
            ]
          }
        ]

  ## Implementation Details

  - Each worker runs a single-threaded Python process
  - Workers are single-capacity (one request at a time)
  - Environment variables enforce single-threading in scientific libraries
  - Startup is batched to prevent resource exhaustion
  """

  @behaviour Snakepit.WorkerProfile

  require Logger

  @impl true
  def start_worker(config) do
    worker_id = Map.fetch!(config, :worker_id)
    worker_module = Map.get(config, :worker_module, Snakepit.GRPCWorker)
    adapter_module = Map.fetch!(config, :adapter_module)
    pool_name = Map.get(config, :pool_name, Snakepit.Pool)

    # Build adapter environment with single-threading enforcement
    _adapter_env = build_process_env(config)

    # Start the worker via the WorkerSupervisor, passing worker_config for lifecycle management
    case Snakepit.Pool.WorkerSupervisor.start_worker(
           worker_id,
           worker_module,
           adapter_module,
           pool_name,
           config
         ) do
      {:ok, pid} ->
        Logger.debug("Process profile started worker #{worker_id}: #{inspect(pid)}")
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop_worker(worker_pid) when is_pid(worker_pid) do
    # Graceful shutdown via supervisor
    case Registry.lookup(Snakepit.Pool.Registry, worker_pid) do
      [{_pid, %{worker_id: worker_id}}] ->
        Snakepit.Pool.WorkerSupervisor.stop_worker(worker_id)

      [] ->
        # Worker not found, may already be stopped
        :ok
    end
  end

  def stop_worker(worker_id) when is_binary(worker_id) do
    Snakepit.Pool.WorkerSupervisor.stop_worker(worker_id)
  end

  @impl true
  def execute_request(worker_pid, request, timeout) when is_pid(worker_pid) do
    command = Map.fetch!(request, :command)
    args = Map.get(request, :args, %{})

    # Use the worker module's execute function
    worker_module = get_worker_module(worker_pid)
    worker_module.execute(worker_pid, command, args, timeout)
  end

  def execute_request(worker_id, request, timeout) when is_binary(worker_id) do
    # Lookup PID from worker_id
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] ->
        execute_request(pid, request, timeout)

      [] ->
        {:error, :worker_not_found}
    end
  end

  @impl true
  def get_capacity(_worker_handle) do
    # Process profile: single-threaded, capacity = 1
    1
  end

  @impl true
  def get_load(_worker_handle) do
    # For process profile, load is binary: 0 (idle) or 1 (busy)
    # This information is tracked by the pool, not the worker itself
    # Return 0 as workers don't maintain their own load state
    # The pool's busy/available sets track actual load
    0
  end

  @impl true
  def health_check(worker_handle) when is_pid(worker_handle) do
    if Process.alive?(worker_handle) do
      # Could optionally send a ping command
      :ok
    else
      {:error, :worker_dead}
    end
  end

  def health_check(worker_id) when is_binary(worker_id) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _}] ->
        health_check(pid)

      [] ->
        {:error, :worker_not_found}
    end
  end

  @impl true
  def get_metadata(worker_handle) when is_pid(worker_handle) do
    {:ok,
     %{
       profile: :process,
       capacity: 1,
       worker_type: "single-process",
       threading: "single-threaded"
     }}
  end

  def get_metadata(worker_id) when is_atom(worker_id) do
    # Handle atom input (for tests with :fake_worker, etc.)
    {:ok,
     %{
       profile: :process,
       capacity: 1,
       worker_type: "single-process",
       threading: "single-threaded"
     }}
  end

  def get_metadata(worker_id) when is_binary(worker_id) do
    {:ok,
     %{
       profile: :process,
       capacity: 1,
       worker_type: "single-process",
       threading: "single-threaded",
       worker_id: worker_id
     }}
  end

  # Private helpers

  @all_thread_control_vars [
    "OPENBLAS_NUM_THREADS",
    "MKL_NUM_THREADS",
    "OMP_NUM_THREADS",
    "NUMEXPR_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
    # macOS Accelerate
    "GRPC_POLL_STRATEGY"
  ]

  defp build_process_env(config) do
    # Start with comprehensive single-threading defaults
    default_env =
      Enum.map(@all_thread_control_vars, fn var ->
        case var do
          "GRPC_POLL_STRATEGY" -> {var, "poll"}
          _ -> {var, "1"}
        end
      end)

    # Get user-specified environment (overrides defaults)
    user_env = Map.get(config, :adapter_env, [])

    # Merge: user env overrides defaults
    merged =
      Enum.reduce(user_env, Map.new(default_env), fn {key, val}, acc ->
        Map.put(acc, key, val)
      end)

    # Convert back to list of tuples
    Map.to_list(merged)
  end

  defp get_worker_module(worker_pid) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_pid) do
      [{_pid, %{worker_module: module}}] ->
        module

      _ ->
        # Default to GRPCWorker
        Snakepit.GRPCWorker
    end
  end
end
