defmodule Snakepit.Pool.Worker.StarterRegistry do
  @moduledoc """
  Registry for worker starter supervisors.

  This registry provides a clean separation between worker processes and
  their starter supervisors, making debugging and process tracking easier.

  Worker starters are registered with their worker_id as the key, allowing
  for easy lookup and management of individual starter supervisors.
  """

  @registry_name __MODULE__

  @doc """
  Returns the child spec for the starter registry.
  """
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: @registry_name
    )
  end

  @doc """
  Returns a via tuple for registering/looking up a worker starter supervisor.

  ## Examples

      iex> Snakepit.Pool.Worker.StarterRegistry.via_tuple("worker_123")
      {:via, Registry, {Snakepit.Pool.Worker.StarterRegistry, "worker_123"}}
  """
  def via_tuple(worker_id) when is_binary(worker_id) do
    {:via, Registry, {@registry_name, worker_id}}
  end

  @doc """
  Lists all registered worker starter IDs.
  """
  def list_starters do
    Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Checks if a worker starter is registered.
  """
  def starter_exists?(worker_id) do
    case Registry.lookup(@registry_name, worker_id) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Gets the PID for a worker starter supervisor.
  """
  def get_starter_pid(worker_id) do
    case Registry.lookup(@registry_name, worker_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Counts the number of registered worker starters.
  """
  def starter_count do
    Registry.count(@registry_name)
  end
end
