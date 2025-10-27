defmodule Snakepit.Pool.ClientCancellationTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool

  @telemetry_event [:snakepit, :request, :executed]

  setup do
    Application.ensure_all_started(:snakepit)
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
end
