defmodule Snakepit.Pool.Registry do
  @moduledoc """
  Registry for pool worker processes.

  This is a thin wrapper around Elixir's Registry that provides:
  - Consistent naming for worker processes
  - Easy migration path to distributed registry (Horde)
  - Helper functions for worker lookup
  """

  @registry_name __MODULE__

  @doc """
  Returns the child spec for the registry.
  """
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: @registry_name
    )
  end

  @doc """
  Returns a via tuple for registering/looking up a worker process.

  ## Examples

      iex> Snakepit.Pool.Registry.via_tuple("worker_123")
      {:via, Registry, {Snakepit.Pool.Registry, "worker_123"}}
  """
  def via_tuple(worker_id) when is_binary(worker_id) do
    {:via, Registry, {@registry_name, worker_id}}
  end

  @doc """
  Lists all registered worker IDs.
  """
  def list_workers do
    Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Checks if a worker is registered.
  """
  def worker_exists?(worker_id) do
    case Registry.lookup(@registry_name, worker_id) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Gets the PID for a worker ID.
  """
  def get_worker_pid(worker_id) do
    case Registry.lookup(@registry_name, worker_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Counts the number of registered workers.
  """
  def worker_count do
    Registry.count(@registry_name)
  end

  @doc """
  Register a worker with metadata for O(1) reverse lookups.
  This is only used for manual registration - workers started with via_tuple are already registered.
  """
  def register_worker(_worker_id, _pid) do
    # Workers started with via_tuple are already registered automatically
    # This is a no-op for compatibility
    :ok
  end

  @doc """
  Get worker_id from PID for O(1) lookups in :DOWN messages.
  """
  def get_worker_id_by_pid(pid) do
    # Use Registry's keys/2 function for O(1) reverse lookup
    case Registry.keys(@registry_name, pid) do
      [worker_id] -> {:ok, worker_id}
      [] -> {:error, :not_found}
    end
  end
end
