defmodule Snakepit.GRPCWorkerStreamCorrelationTest do
  use ExUnit.Case, async: true

  defmodule CaptureAdapter do
    def grpc_execute_stream(_connection, _session_id, _command, args, _callback_fn, _timeout) do
      if test_pid = Process.get(:test_pid) do
        send(test_pid, {:captured_stream_args, args})
      end

      :ok
    end
  end

  test "execute_stream ensures correlation_id in args" do
    Process.put(:test_pid, self())

    state = %{
      adapter: CaptureAdapter,
      connection: :fake_connection,
      session_id: "session-stream",
      stats: %{requests: 0, errors: 0}
    }

    callback = fn _chunk -> :ok end

    {:reply, :ok, _new_state} =
      Snakepit.GRPCWorker.handle_call(
        {:execute_stream, "stream_cmd", %{"payload" => "data"}, callback, 5_000},
        {self(), make_ref()},
        state
      )

    assert_receive {:captured_stream_args, args}
    assert is_binary(args["correlation_id"])
    refute args["correlation_id"] == ""
  end
end
