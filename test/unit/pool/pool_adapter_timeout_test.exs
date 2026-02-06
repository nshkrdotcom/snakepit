defmodule Snakepit.Pool.AdapterTimeoutTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool

  defmodule PoolAdapter do
    def command_timeout(_command, _args), do: 1_111
  end

  defmodule GlobalAdapter do
    def command_timeout(_command, _args), do: 2_222
  end

  defmodule TimeoutProbeWorker do
    def execute(_worker_id, _command, args, opts) do
      test_pid = Map.get(args, :test_pid) || Map.get(args, "test_pid")
      send(test_pid, {:timeout_used, Keyword.get(opts, :timeout)})
      {:ok, :done}
    end
  end

  setup do
    previous = Application.get_env(:snakepit, :adapter_module)
    Application.put_env(:snakepit, :adapter_module, GlobalAdapter)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:snakepit, :adapter_module)
      else
        Application.put_env(:snakepit, :adapter_module, previous)
      end
    end)

    :ok
  end

  test "uses worker/pool adapter_module for command_timeout" do
    worker_id = "timeout_pool_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Registry.register(Snakepit.Pool.Registry, worker_id, %{
               worker_module: TimeoutProbeWorker,
               adapter_module: PoolAdapter,
               pool_name: :default
             })

    state = base_state(worker_id)
    from = {self(), make_ref()}
    tag = elem(from, 1)

    assert {:noreply, _new_state} =
             Pool.handle_call({:execute, "ping", %{test_pid: self()}, []}, from, state)

    assert_receive {:timeout_used, 1_111}, 500
    assert_receive {^tag, {:ok, :done}}, 500
  end

  test "falls back to global adapter_module when worker metadata omits adapter" do
    worker_id = "timeout_global_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Registry.register(Snakepit.Pool.Registry, worker_id, %{
               worker_module: TimeoutProbeWorker,
               pool_name: :default
             })

    state = base_state(worker_id)
    from = {self(), make_ref()}
    tag = elem(from, 1)

    assert {:noreply, _new_state} =
             Pool.handle_call({:execute, "ping", %{test_pid: self()}, []}, from, state)

    assert_receive {:timeout_used, 2_222}, 500
    assert_receive {^tag, {:ok, :done}}, 500
  end

  defp base_state(worker_id) do
    affinity_cache =
      :ets.new(:"affinity_cache_#{System.unique_integer([:positive])}", [:set, :private])

    pool_state = %{
      name: :default,
      initialized: true,
      init_failed: false,
      workers: [worker_id],
      available: MapSet.new([worker_id]),
      ready_workers: MapSet.new([worker_id]),
      worker_loads: %{},
      worker_capacities: %{worker_id => 1},
      capacity_strategy: :pool,
      request_queue: :queue.new(),
      cancelled_requests: %{},
      queue_timeout: 1_000,
      max_queue_size: 100,
      pool_config: %{},
      stats: %{requests: 0, queued: 0, errors: 0, queue_timeouts: 0, pool_saturated: 0}
    }

    %Pool{
      pools: %{default: pool_state},
      affinity_cache: affinity_cache,
      default_pool: :default
    }
  end
end
