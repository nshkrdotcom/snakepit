defmodule Snakepit.Pool.DispatchTelemetryTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool
  alias Snakepit.Pool.State

  @dispatch_event [:snakepit, :pool, :call, :dispatched]

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    Application.load(:snakepit)
    configure_pooling()

    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Pool.await_ready()

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  test "emits dispatch telemetry for direct worker assignment" do
    handler_id = "pool-dispatch-direct-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @dispatch_event,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    state = :sys.get_state(Pool)
    pool_name = state.default_pool
    pool_state = Map.fetch!(state.pools, pool_name)

    worker_id =
      case pool_state.workers do
        [id | _] -> id
        [] -> flunk("pool #{inspect(pool_name)} had no workers to test with")
      end

    command = "dispatch_direct_ping"
    dead_client = spawn(fn -> :ok end)
    Process.exit(dead_client, :kill)
    from = {dead_client, make_ref()}

    {:noreply, _new_state} = Pool.handle_call({:execute, command, %{}, %{}}, from, state)

    assert_receive {:telemetry, @dispatch_event, measurements,
                    %{pool: ^pool_name, worker_id: ^worker_id, command: ^command, queued: false}},
                   2_000

    assert is_integer(measurements.system_time)
  end

  test "emits dispatch telemetry for queued request assignment" do
    handler_id = "pool-dispatch-queued-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @dispatch_event,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    state = :sys.get_state(Pool)
    pool_name = state.default_pool
    pool_state = Map.fetch!(state.pools, pool_name)

    worker_id =
      case pool_state.workers do
        [id | _] -> id
        [] -> flunk("pool #{inspect(pool_name)} had no workers to test with")
      end

    command = "dispatch_queued_ping"
    dead_client = spawn(fn -> :ok end)
    Process.exit(dead_client, :kill)
    from = {dead_client, make_ref()}

    busy_pool_state = State.increment_worker_load(pool_state, worker_id)
    busy_state = put_in(state.pools[pool_name], busy_pool_state)

    {:noreply, queued_state} =
      Pool.handle_call({:execute, command, %{}, %{}}, from, busy_state)

    refute_receive {:telemetry, @dispatch_event, _measurements, _metadata}, 200

    {:noreply, _after_checkin_state} =
      Pool.handle_cast({:checkin_worker, pool_name, worker_id, :skip_decrement}, queued_state)

    assert_receive {:telemetry, @dispatch_event, measurements,
                    %{pool: ^pool_name, worker_id: ^worker_id, command: ^command, queued: true}},
                   2_000

    assert is_integer(measurements.system_time)
  end

  defp configure_pooling do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
      }
    ])

    Application.put_env(:snakepit, :adapter_module, Snakepit.TestAdapters.MockGRPCAdapter)
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      adapter_module: Application.get_env(:snakepit, :adapter_module)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
