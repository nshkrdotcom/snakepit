defmodule Snakepit.Pool.Worker.Starter do
  @moduledoc """
  Supervisor wrapper for individual workers that provides automatic restart capability.

  This module implements the "Permanent Wrapper" pattern that allows DynamicSupervisor
  to automatically restart workers when they crash, while keeping the actual worker
  process as :transient (so it doesn't restart during coordinated shutdown).

  ## Architecture

  ```
  DynamicSupervisor (WorkerSupervisor)
  └── Worker.Starter (permanent, one per worker)
      └── Worker (transient, actual worker process)
  ```

  When a Worker crashes:
  1. Worker.Starter detects the crash via its :one_for_one strategy
  2. Worker.Starter automatically restarts the Worker (because Worker is :permanent in this context)
  3. Pool is notified via :DOWN message but doesn't need to manage restarts
  4. New Worker re-registers itself automatically

  This decouples the Pool from worker replacement logic.
  """

  use Supervisor
  require Logger

  @doc """
  Starts a worker starter supervisor.

  ## Parameters

    * `worker_id` - Unique identifier for the worker
  """
  def start_link(worker_id) when is_binary(worker_id) do
    Supervisor.start_link(__MODULE__, {worker_id, Snakepit.Pool.Worker},
      name: via_name(worker_id)
    )
  end

  def start_link({worker_id, worker_module}) when is_binary(worker_id) do
    Supervisor.start_link(__MODULE__, {worker_id, worker_module}, name: via_name(worker_id))
  end

  @doc """
  Returns a via tuple for this starter supervisor.
  """
  def via_name(worker_id) do
    Snakepit.Pool.Worker.StarterRegistry.via_tuple(worker_id)
  end

  @impl true
  def init({worker_id, worker_module}) do
    # Check if the Pool is already terminating
    case Process.whereis(Snakepit.Pool) do
      nil ->
        # Pool is dead, don't start workers
        Logger.debug("Aborting worker starter for #{worker_id} - Pool is dead")
        :ignore

      _pid ->
        Logger.debug(
          "Starting worker starter for #{worker_id} with module #{inspect(worker_module)}"
        )

        adapter = Application.get_env(:snakepit, :adapter_module)

        children = [
          %{
            id: worker_id,
            start: {worker_module, :start_link, [[id: worker_id, adapter: adapter]]},
            # Within this supervisor, the worker restarts on crashes but not during shutdown
            restart: :transient,
            type: :worker
          }
        ]

        Supervisor.init(children, strategy: :one_for_one)
    end
  end
end
