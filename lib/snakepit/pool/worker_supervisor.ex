defmodule Snakepit.Pool.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor for pool worker processes.

  This supervisor manages the lifecycle of workers:
  - Starts workers on demand
  - Handles crashes with automatic restarts
  - Provides clean shutdown of workers
  """

  use DynamicSupervisor
  require Logger

  @doc """
  Starts the worker supervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: []
    )
  end

  @doc """
  Starts a new pool worker with the given ID.

  ## Examples

      iex> Snakepit.Pool.WorkerSupervisor.start_worker("worker_123")
      {:ok, #PID<0.123.0>}
  """
  def start_worker(worker_id, worker_module \\ Snakepit.GRPCWorker) when is_binary(worker_id) do
    # Start the permanent starter supervisor, not the transient worker directly
    # This gives us automatic worker restarts without Pool intervention
    child_spec = {Snakepit.Pool.Worker.Starter, {worker_id, worker_module}}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, starter_pid} ->
        Logger.info("Started worker starter for #{worker_id} with PID #{inspect(starter_pid)}")
        {:ok, starter_pid}

      {:error, {:already_started, starter_pid}} ->
        Logger.debug(
          "Worker starter for #{worker_id} already running with PID #{inspect(starter_pid)}"
        )

        {:ok, starter_pid}

      {:error, reason} = error ->
        Logger.error("Failed to start worker starter for #{worker_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops a worker gracefully.
  """
  def stop_worker(worker_id) do
    case Snakepit.Pool.Registry.get_worker_pid(worker_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      {:error, :not_found} ->
        {:error, :worker_not_found}
    end
  end

  @doc """
  Lists all supervised workers.
  """
  def list_workers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&Process.alive?/1)
  end

  @doc """
  Returns the count of active workers.
  """
  def worker_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Restarts a worker by ID.
  """
  def restart_worker(worker_id) do
    case Snakepit.Pool.Registry.get_worker_pid(worker_id) do
      {:ok, old_pid} ->
        # Worker exists, terminate it and wait for cleanup before starting new one
        with :ok <- DynamicSupervisor.terminate_child(__MODULE__, old_pid),
             :ok <- wait_for_worker_cleanup(old_pid) do
          start_worker(worker_id)
        else
          # Propagate termination/cleanup errors
          error -> error
        end

      {:error, :not_found} ->
        # Worker doesn't exist, so we just need to start it
        start_worker(worker_id)
    end
  end

  @cleanup_retry_interval Application.compile_env(:snakepit, :cleanup_retry_interval, 100)
  @cleanup_max_retries Application.compile_env(:snakepit, :cleanup_max_retries, 10)

  # Wait for a specific PID to terminate to avoid race conditions
  defp wait_for_worker_cleanup(pid, retries \\ @cleanup_max_retries) do
    if retries > 0 and Process.alive?(pid) do
      # Monitor the specific PID we want to wait for
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        @cleanup_retry_interval ->
          Process.demonitor(ref, [:flush])
          wait_for_worker_cleanup(pid, retries - 1)
      end
    else
      if Process.alive?(pid) do
        {:error, :cleanup_timeout}
      else
        :ok
      end
    end
  end
end
