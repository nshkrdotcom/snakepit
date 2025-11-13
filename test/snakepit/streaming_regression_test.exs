defmodule Snakepit.StreamingRegressionTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  defmodule NoStreamAdapter do
    @behaviour Snakepit.Adapter

    @impl true
    def executable_path, do: "false"

    @impl true
    def script_path, do: ""

    @impl true
    def script_args, do: []

    @impl true
    def supported_commands, do: []

    @impl true
    def validate_command(_command, _args), do: :ok

    def uses_grpc?, do: false
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :ok = Snakepit.Pool.await_ready()
    :ok
  end

  test "execute_stream streams python chunks in order" do
    parent = self()

    callback = fn chunk ->
      send(parent, {:chunk, chunk})
      :ok
    end

    assert :ok =
             Snakepit.execute_stream(
               "stream_progress",
               %{"steps" => 5},
               callback,
               timeout: 15_000
             )

    chunks =
      Enum.map(1..5, fn expected_step ->
        assert_receive {:chunk, chunk}, 5_000
        assert chunk["step"] == expected_step
        assert chunk["total"] == 5
        chunk
      end)

    assert Enum.at(chunks, -1)["is_final"]
    refute_receive {:chunk, _}, 200
  end

  test "execute_stream fails when adapter does not expose gRPC streaming" do
    original = Application.get_env(:snakepit, :adapter_module)
    on_exit(fn -> Application.put_env(:snakepit, :adapter_module, original) end)

    Application.put_env(:snakepit, :adapter_module, NoStreamAdapter)

    assert {:error,
            %Snakepit.Error{category: :validation, message: "Streaming not supported by adapter"}} =
             Snakepit.execute_stream("stream_progress", %{}, fn _ -> :ok end)
  end

  test "client cancellation checks worker back into the pool" do
    handler_id = "stream-cancel-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:snakepit, :request, :executed],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stats_before = Snakepit.Pool.get_stats()
    assert stats_before.available == stats_before.workers

    chunk_limit = 3

    callback = fn chunk ->
      send(test_pid, {:chunk, chunk})

      if chunk["step"] >= chunk_limit do
        :halt
      else
        :ok
      end
    end

    assert :ok =
             Snakepit.execute_stream(
               "stream_progress",
               %{"steps" => 10, "delay_ms" => 50},
               callback,
               timeout: 30_000
             )

    Enum.each(1..chunk_limit, fn expected_step ->
      assert_receive {:chunk, chunk}, 5_000
      assert chunk["step"] == expected_step
    end)

    refute_receive {:chunk, _}, 200

    assert_receive {:telemetry, [:snakepit, :request, :executed], %{duration_us: _}, metadata},
                   5_000

    assert metadata.success

    # Worker pool should report all workers available after the aborted stream.
    assert_eventually(
      fn ->
        stats = Snakepit.Pool.get_stats()
        stats.available == stats.workers
      end,
      timeout: 5_000,
      interval: 100
    )
  end
end
