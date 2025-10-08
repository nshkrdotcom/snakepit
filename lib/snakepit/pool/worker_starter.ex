defmodule Snakepit.Pool.Worker.Starter do
  @moduledoc """
  Supervisor wrapper for individual workers that provides automatic restart capability.

  This module implements the "Permanent Wrapper" pattern for managing workers that
  control external OS processes (Python gRPC servers).

  ## Architecture Decision

  **See**: `docs/architecture/adr-001-worker-starter-supervision-pattern.md` for
  detailed rationale, alternatives considered, and trade-offs.

  ## Why This Pattern?

  **TL;DR**: Workers manage external Python processes, not just Elixir state.
  This pattern provides:
  - Automatic restart without Pool intervention
  - Atomic resource cleanup (worker + Python process)
  - Future extensibility for per-worker resources

  **Trade-off**: Extra process (~1KB) per worker for better encapsulation.

  ## Architecture

  ```
  DynamicSupervisor (WorkerSupervisor)
  └── Worker.Starter (Supervisor, :permanent)
      └── GRPCWorker (GenServer, :transient)
          └── Port → Python grpc_server.py
  ```

  ## Lifecycle

  **When GRPCWorker crashes**:
  1. Worker.Starter detects crash via :one_for_one strategy
  2. Worker.Starter automatically restarts GRPCWorker
  3. Pool notified via :DOWN but doesn't manage restart
  4. New GRPCWorker spawns new Python process and re-registers

  **When Worker.Starter terminates**:
  1. GRPCWorker receives shutdown signal
  2. GRPCWorker.terminate sends SIGTERM to Python
  3. Python process exits gracefully
  4. Worker.Starter confirms all children stopped
  5. Clean atomic shutdown

  This decouples Pool (availability management) from Worker lifecycle (crash/restart).

  ## Related

  - **Issue #2**: Community feedback questioning this complexity
  - **ADR-001**: Full architecture decision record with alternatives
  - **External Process Design**: `docs/20251007_external_process_supervision_design.md`
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

  def start_link({worker_id, worker_module, adapter_module}) when is_binary(worker_id) do
    Supervisor.start_link(__MODULE__, {worker_id, worker_module, adapter_module},
      name: via_name(worker_id)
    )
  end

  @doc """
  Returns a via tuple for this starter supervisor.
  """
  def via_name(worker_id) do
    Snakepit.Pool.Worker.StarterRegistry.via_tuple(worker_id)
  end

  @impl true
  def init({worker_id, worker_module}) do
    init({worker_id, worker_module, nil})
  end

  def init({worker_id, worker_module, adapter_module}) do
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

        adapter = adapter_module || Application.get_env(:snakepit, :adapter_module)

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
