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

  test "DOWN cleanup removes orphaned pending monitor entries" do
    monitor_ref = make_ref()
    token = make_ref()

    state = %{
      id: "worker-monitor-cleanup",
      stats: %{requests: 0, errors: 0},
      pending_rpc_calls: %{},
      pending_rpc_monitors: %{monitor_ref => token}
    }

    assert {:noreply, new_state} =
             Snakepit.GRPCWorker.handle_info(
               {:DOWN, monitor_ref, :process, self(), :simulated_crash},
               state
             )

    refute Map.has_key?(new_state.pending_rpc_monitors, monitor_ref)
    assert new_state.pending_rpc_calls == %{}
  end

  test "async result followed by DOWN keeps pending monitor maps clean" do
    monitor_ref = make_ref()
    token = make_ref()
    from = {self(), make_ref()}
    tag = elem(from, 1)

    state = %{
      id: "worker-rpc-ordering",
      stats: %{requests: 0, errors: 0},
      pending_rpc_calls: %{token => %{from: from, monitor_ref: monitor_ref, task_pid: self()}},
      pending_rpc_monitors: %{monitor_ref => token}
    }

    assert {:noreply, after_result} =
             Snakepit.GRPCWorker.handle_info(
               {:grpc_async_rpc_result, token, {:ok, {{:ok, :done}, :success}}},
               state
             )

    assert_receive {^tag, {:ok, :done}}, 500
    assert after_result.pending_rpc_calls == %{}
    assert after_result.pending_rpc_monitors == %{}

    assert {:noreply, after_down} =
             Snakepit.GRPCWorker.handle_info(
               {:DOWN, monitor_ref, :process, self(), :simulated_crash},
               after_result
             )

    assert after_down.pending_rpc_calls == %{}
    assert after_down.pending_rpc_monitors == %{}
  end
end
