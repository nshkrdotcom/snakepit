defmodule Snakepit.Pool.ClientCancellationTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool

  @telemetry_event [:snakepit, :request, :executed]

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

  test "emits aborted telemetry when client dies before execution" do
    handler_id = "pool-client-cancel-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok = Pool.await_ready()

    state = :sys.get_state(Pool)
    pool_name = state.default_pool
    pool_state = Map.fetch!(state.pools, pool_name)

    _worker_id =
      case pool_state.workers do
        [id | _] -> id
        [] -> flunk("pool #{inspect(pool_name)} had no workers to test with")
      end

    dead_client = spawn(fn -> :ok end)
    Process.exit(dead_client, :kill)
    from = {dead_client, make_ref()}

    {:noreply, _} = Pool.handle_call({:execute, "ping", %{}, %{}}, from, state)

    assert_receive {:telemetry, @telemetry_event, measurements, %{command: "ping"} = metadata},
                   2_000

    refute metadata.success
    assert metadata.aborted
    assert metadata.reason == :client_down
    assert measurements.duration_us >= 0
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
