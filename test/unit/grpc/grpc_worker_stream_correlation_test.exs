defmodule Snakepit.GRPCWorkerStreamCorrelationTest do
  use ExUnit.Case, async: true

  defmodule CaptureAdapter do
    def grpc_execute_stream(
          _connection,
          _session_id,
          _command,
          args,
          _callback_fn,
          _timeout,
          _opts
        ) do
      test_pid = args["test_pid"] || args[:test_pid] || Process.get(:test_pid)

      if is_pid(test_pid) do
        send(test_pid, {:captured_stream_args, args})
      end

      :ok
    end
  end

  test "execute_stream ensures correlation_id in args" do
    tag = make_ref()
    from = {self(), tag}

    state = %{
      adapter: CaptureAdapter,
      connection: :fake_connection,
      session_id: "session-stream",
      stats: %{requests: 0, errors: 0},
      pending_rpc_calls: %{},
      pending_rpc_monitors: %{}
    }

    callback = fn _chunk -> :ok end

    {:noreply, state_after_call} =
      Snakepit.GRPCWorker.handle_call(
        {:execute_stream, "stream_cmd", %{"payload" => "data", "test_pid" => self()}, callback,
         5_000},
        from,
        state
      )

    assert_receive {:captured_stream_args, args}, 500
    assert is_binary(args["correlation_id"])
    refute args["correlation_id"] == ""

    assert_receive {:grpc_async_rpc_result, token, {:ok, {:ok, :success}}}, 500

    {:noreply, _state_after_result} =
      Snakepit.GRPCWorker.handle_info(
        {:grpc_async_rpc_result, token, {:ok, {:ok, :success}}},
        state_after_call
      )

    assert_receive {^tag, :ok}, 500
  end
end
