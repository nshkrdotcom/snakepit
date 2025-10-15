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
  alias Snakepit.Logger, as: SLog

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
    Supervisor.start_link(__MODULE__, {worker_id, worker_module, adapter_module, nil},
      name: via_name(worker_id)
    )
  end

  def start_link({worker_id, worker_module, adapter_module, pool_name})
      when is_binary(worker_id) do
    Supervisor.start_link(__MODULE__, {worker_id, worker_module, adapter_module, pool_name, %{}},
      name: via_name(worker_id)
    )
  end

  def start_link({worker_id, worker_module, adapter_module, pool_name, worker_config})
      when is_binary(worker_id) do
    Supervisor.start_link(
      __MODULE__,
      {worker_id, worker_module, adapter_module, pool_name, worker_config},
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
    init({worker_id, worker_module, nil, nil, %{}})
  end

  def init({worker_id, worker_module, adapter_module}) do
    init({worker_id, worker_module, adapter_module, nil, %{}})
  end

  def init({worker_id, worker_module, adapter_module, pool_name}) do
    init({worker_id, worker_module, adapter_module, pool_name, %{}})
  end

  def init({worker_id, worker_module, adapter_module, pool_name, worker_config}) do
    # Check if the Pool is already terminating
    # For dynamic pools, we can't check a specific name, so skip this check if pool_name is a PID
    should_check_global_pool = pool_name == nil || pool_name == Snakepit.Pool

    if should_check_global_pool do
      case Process.whereis(Snakepit.Pool) do
        nil ->
          # Global pool is dead, don't start workers
          SLog.debug("Aborting worker starter for #{worker_id} - Global pool is dead")
          :ignore

        _pid ->
          do_init_worker(worker_id, worker_module, adapter_module, pool_name, worker_config)
      end
    else
      # Using a custom pool (like in tests), always proceed
      do_init_worker(worker_id, worker_module, adapter_module, pool_name, worker_config)
    end
  end

  defp do_init_worker(worker_id, worker_module, adapter_module, pool_name, worker_config) do
    SLog.debug("Starting worker starter for #{worker_id} with module #{inspect(worker_module)}")

    adapter = adapter_module || Application.get_env(:snakepit, :adapter_module)

    # CRITICAL FIX: Pass pool_name to worker so it knows which pool to notify when ready
    # Default to Snakepit.Pool for backward compatibility (production use)
    # v0.6.0: Pass worker_config for lifecycle management
    worker_opts = [
      id: worker_id,
      adapter: adapter,
      pool_name: pool_name || Snakepit.Pool,
      worker_config: worker_config
    ]

    children = [
      %{
        id: worker_id,
        start: {worker_module, :start_link, [worker_opts]},
        # Within this supervisor, the worker restarts on crashes but not during shutdown
        restart: :transient,
        # CRITICAL: Give worker time to gracefully shutdown (send SIGTERM, wait for Python)
        # Default is 5000ms, but we explicitly set it to ensure it's not :brutal_kill
        shutdown: 5000,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
