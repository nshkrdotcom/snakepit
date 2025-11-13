defmodule Snakepit.Pool.Registry do
  @moduledoc """
  Registry for pool worker processes.

  This is a thin wrapper around Elixir's Registry that provides:
  - Consistent naming for worker processes
  - Easy migration path to distributed registry (Horde)
  - Helper functions for worker lookup
  """

  require Logger

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
    match?({:ok, _pid, _meta}, fetch_worker(worker_id))
  end

  @doc """
  Gets the PID for a worker ID.
  """
  def get_worker_pid(worker_id) do
    with {:ok, pid, _metadata} <- fetch_worker(worker_id) do
      {:ok, pid}
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
  Adds or updates metadata for a registered worker.

  Accepts maps to keep metadata consistent across callers. When `Registry`
  has `nil` metadata (the default when using `:via` tuples), this function
  replaces it with the provided map. Future updates merge with the existing map.

  Returns `:ok` on success or `{:error, :not_registered}` if the worker has
  not been registered yet (best-effort semantics).
  """
  def put_metadata(worker_id, metadata) when is_binary(worker_id) and is_map(metadata) do
    sanitized = normalize_metadata(metadata)

    try do
      case Registry.update_value(@registry_name, worker_id, fn
             current when is_map(current) -> Map.merge(current, sanitized)
             _ -> sanitized
           end) do
        {_, _} ->
          :ok

        :error ->
          Logger.debug(
            "Pool.Registry.put_metadata/2 attempted to update #{inspect(worker_id)} before registration"
          )

          {:error, :not_registered}
      end
    rescue
      ArgumentError ->
        Logger.debug(
          "Pool.Registry.put_metadata/2 attempted to update #{inspect(worker_id)} before registration"
        )

        {:error, :not_registered}
    end
  end

  def put_metadata(_worker_id, _metadata), do: :ok

  @doc """
  Returns `{pid, metadata}` for a registered worker.
  """
  def fetch_worker(worker_id) when is_binary(worker_id) do
    case Registry.lookup(@registry_name, worker_id) do
      [{pid, metadata}] ->
        {:ok, pid, normalize_metadata(metadata)}

      [] ->
        {:error, :not_found}
    end
  end

  def fetch_worker(_worker_id), do: {:error, :invalid_worker_id}

  @doc """
  Returns only the metadata for a worker.
  """
  def get_worker_metadata(worker_id) do
    with {:ok, _pid, metadata} <- fetch_worker(worker_id) do
      {:ok, metadata}
    end
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

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
