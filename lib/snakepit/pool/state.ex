defmodule Snakepit.Pool.State do
  @moduledoc false

  alias Snakepit.Config
  alias Snakepit.Defaults

  defstruct [
    :name,
    :size,
    :workers,
    :available,
    :worker_loads,
    :worker_capacities,
    :capacity_strategy,
    :request_queue,
    :cancelled_requests,
    :stats,
    :initialized,
    :startup_timeout,
    :queue_timeout,
    :max_queue_size,
    :worker_module,
    :adapter_module,
    :pool_config,
    initialization_waiters: []
  ]

  def build_pool_state(opts, pool_config, multi_pool_mode?) do
    pool_name = Map.get(pool_config, :name, :default)

    # Extract pool settings with backward-compatible fallbacks
    # In multi-pool mode, ALWAYS use per-pool pool_size (ignore opts[:size] from legacy config)
    # In legacy mode, use opts[:size] (from application.ex) or fall back to pool_config/default
    size = resolve_pool_size(opts, pool_config, multi_pool_mode?)

    startup_timeout = Defaults.pool_startup_timeout()
    queue_timeout = Defaults.pool_queue_timeout()
    max_queue_size = Defaults.pool_max_queue_size()

    worker_module = opts[:worker_module] || Snakepit.GRPCWorker

    adapter_module =
      opts[:adapter_module] ||
        Map.get(pool_config, :adapter_module) ||
        Application.get_env(:snakepit, :adapter_module)

    %__MODULE__{
      name: pool_name,
      size: size,
      workers: [],
      available: MapSet.new(),
      worker_loads: %{},
      worker_capacities: %{},
      capacity_strategy: resolve_capacity_strategy(pool_config),
      request_queue: :queue.new(),
      cancelled_requests: %{},
      stats: %{
        requests: 0,
        queued: 0,
        errors: 0,
        queue_timeouts: 0,
        pool_saturated: 0
      },
      initialized: false,
      startup_timeout: startup_timeout,
      queue_timeout: queue_timeout,
      max_queue_size: max_queue_size,
      worker_module: worker_module,
      adapter_module: adapter_module,
      pool_config: pool_config
    }
  end

  def build_worker_capacities(pool_state, workers) do
    Enum.reduce(workers, pool_state.worker_capacities, fn worker_id, acc ->
      Map.put_new(acc, worker_id, resolve_worker_capacity(pool_state, worker_id))
    end)
  end

  def ensure_worker_capacity(pool_state, worker_id) do
    if Map.has_key?(pool_state.worker_capacities, worker_id) do
      pool_state
    else
      capacity = resolve_worker_capacity(pool_state, worker_id)

      %{
        pool_state
        | worker_capacities: Map.put(pool_state.worker_capacities, worker_id, capacity)
      }
    end
  end

  def ensure_worker_available(pool_state, worker_id) do
    load = worker_load(pool_state, worker_id)
    capacity = effective_capacity(pool_state, worker_id)

    if load < capacity do
      %{pool_state | available: MapSet.put(pool_state.available, worker_id)}
    else
      pool_state
    end
  end

  def increment_worker_load(pool_state, worker_id) do
    pool_state = ensure_worker_capacity(pool_state, worker_id)
    new_load = worker_load(pool_state, worker_id) + 1
    capacity = effective_capacity(pool_state, worker_id)

    new_loads = Map.put(pool_state.worker_loads, worker_id, new_load)

    new_available =
      if new_load < capacity do
        MapSet.put(pool_state.available, worker_id)
      else
        MapSet.delete(pool_state.available, worker_id)
      end

    %{
      pool_state
      | worker_loads: new_loads,
        available: new_available
    }
  end

  def decrement_worker_load(pool_state, worker_id) do
    pool_state = ensure_worker_capacity(pool_state, worker_id)
    current_load = worker_load(pool_state, worker_id)
    new_load = max(current_load - 1, 0)
    capacity = effective_capacity(pool_state, worker_id)

    new_loads =
      if new_load > 0 do
        Map.put(pool_state.worker_loads, worker_id, new_load)
      else
        Map.delete(pool_state.worker_loads, worker_id)
      end

    new_available =
      if new_load < capacity and Enum.member?(pool_state.workers, worker_id) do
        MapSet.put(pool_state.available, worker_id)
      else
        pool_state.available
      end

    %{
      pool_state
      | worker_loads: new_loads,
        available: new_available
    }
  end

  defp resolve_pool_size(_opts, pool_config, true = _multi_pool_mode?) do
    # Multi-pool mode: use per-pool config only
    Map.get(pool_config, :pool_size, Defaults.default_pool_size())
  end

  defp resolve_pool_size(opts, pool_config, false = _multi_pool_mode?) do
    # Legacy mode: opts[:size] takes precedence
    opts[:size] || Map.get(pool_config, :pool_size, Defaults.default_pool_size())
  end

  defp resolve_capacity_strategy(pool_config) do
    Map.get(pool_config, :capacity_strategy) ||
      Application.get_env(:snakepit, :capacity_strategy, :pool)
  end

  defp worker_load(pool_state, worker_id) do
    Map.get(pool_state.worker_loads, worker_id, 0)
  end

  defp worker_capacity(pool_state, worker_id) do
    Map.get(
      pool_state.worker_capacities,
      worker_id,
      resolve_worker_capacity(pool_state, worker_id)
    )
  end

  defp effective_capacity(pool_state, worker_id) do
    capacity = worker_capacity(pool_state, worker_id)

    case pool_state.capacity_strategy do
      :profile -> 1
      _ -> capacity
    end
  end

  defp resolve_worker_capacity(pool_state, _worker_id) do
    pool_config = pool_state.pool_config || %{}

    capacity =
      if Config.thread_profile?(pool_config) do
        Map.get(pool_config, :threads_per_worker, 1)
      else
        1
      end

    max(capacity, 1)
  end
end
