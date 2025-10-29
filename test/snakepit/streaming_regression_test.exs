defmodule Snakepit.StreamingRegressionTest do
  use ExUnit.Case, async: false

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
end
