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

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  @log_category :worker

  @impl true
  def start_worker(config) do
    worker_id = Map.fetch!(config, :worker_id)
    worker_module = Map.get(config, :worker_module, Snakepit.GRPCWorker)
    adapter_module = Map.fetch!(config, :adapter_module)
    pool_name = Map.get(config, :pool_name, Snakepit.Pool)

    # Build adapter environment with single-threading enforcement
    config_with_env = apply_adapter_env(config)

    # Start the worker via the WorkerSupervisor, passing worker_config for lifecycle management
    case WorkerSupervisor.start_worker(
           worker_id,
           worker_module,
           adapter_module,
           pool_name,
           config_with_env
         ) do
      {:ok, pid} ->
        SLog.debug(@log_category, "Process profile started worker #{worker_id}: #{inspect(pid)}")
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop_worker(worker_pid) when is_pid(worker_pid) do
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
    WorkerSupervisor.stop_worker(worker_id)
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
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        execute_request(pid, request, timeout)

      {:error, _} ->
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
    case PoolRegistry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        health_check(pid)

      {:error, _} ->
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

  @doc false
  def apply_adapter_env(config) when is_map(config) do
    Map.put(config, :adapter_env, build_process_env(config))
  end

  @doc false
  def build_process_env(config) do
    defaults = build_process_env_defaults()
    user_env = Map.get(config, :adapter_env, [])
    merge_env(defaults, user_env)
  end

  defp build_process_env_defaults do
    Enum.map(@all_thread_control_vars, fn var ->
      {var, System.get_env(var) || default_thread_value(var)}
    end)
  end

  defp default_thread_value("GRPC_POLL_STRATEGY"), do: "poll"
  defp default_thread_value(_var), do: "1"

  defp merge_env(defaults, user_env) do
    merged =
      Enum.reduce(normalize_env_entries(user_env), Map.new(defaults), fn {key, val}, acc ->
        Map.put(acc, key, val)
      end)

    Map.to_list(merged)
  end

  defp normalize_env_entries(nil), do: []

  defp normalize_env_entries(env) when is_map(env) do
    env
    |> Map.to_list()
    |> normalize_env_entries()
  end

  defp normalize_env_entries(env) when is_list(env) do
    Enum.flat_map(env, fn
      {key, value} -> [{to_string(key), to_string(value)}]
      key when is_binary(key) -> [{key, ""}]
      key when is_atom(key) -> [{Atom.to_string(key), ""}]
      _ -> []
    end)
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
