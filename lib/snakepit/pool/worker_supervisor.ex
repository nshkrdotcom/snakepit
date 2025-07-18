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
  def start_worker(worker_id) when is_binary(worker_id) do
    child_spec = {
      Snakepit.Pool.Worker,
      id: worker_id
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started pool worker #{worker_id} with PID #{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Worker #{worker_id} already running with PID #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start worker #{worker_id}: #{inspect(reason)}")
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
    with {:ok, _} <- stop_worker(worker_id),
         :ok <- wait_for_worker_cleanup(worker_id),
         {:ok, pid} <- start_worker(worker_id) do
      {:ok, pid}
    end
  end

  # Wait for worker to be fully cleaned up using proper OTP monitoring
  defp wait_for_worker_cleanup(worker_id, retries \\ 10) do
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [] -> 
        # Worker fully cleaned up
        :ok
      [{pid, _}] when retries > 0 ->
        # Worker still exists, set up monitor and wait
        ref = Process.monitor(pid)
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          100 -> 
            Process.demonitor(ref, [:flush])
            wait_for_worker_cleanup(worker_id, retries - 1)
        end
      _ -> 
        # Timeout waiting for cleanup
        {:error, :cleanup_timeout}
    end
  end
end
