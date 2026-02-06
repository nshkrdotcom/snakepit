defmodule Snakepit.GRPCWorkerCallbackNonBlockingTest do
  use ExUnit.Case, async: true

  alias Snakepit.GRPCWorker

  defmodule GatedAdapter do
    def grpc_execute(_conn, _session_id, _command, args, _timeout, _opts) do
      gated_reply(args, {:ok, %{"ok" => true}})
    end

    def grpc_execute_stream(_conn, _session_id, _command, args, _callback_fn, _timeout, _opts) do
      gated_reply(args, :ok)
    end

    defp gated_reply(args, reply) when is_map(args) do
      test_pid = Map.get(args, "test_pid") || Map.get(args, :test_pid)
      gate_ref = Map.get(args, "gate_ref") || Map.get(args, :gate_ref)

      if is_pid(test_pid) and is_reference(gate_ref) do
        send(test_pid, {:adapter_waiting, gate_ref, self()})
      end

      receive do
        {:release, ^gate_ref} -> reply
      after
        5_000 -> {:error, :gate_timeout}
      end
    end
  end

  test "execute callback is non-blocking" do
    state = base_state(GatedAdapter)
    from = {self(), make_ref()}
    gate_ref = make_ref()
    args = %{"test_pid" => self(), "gate_ref" => gate_ref}

    task =
      Task.async(fn ->
        GRPCWorker.handle_call({:execute, "ping", args, 1_000, []}, from, state)
      end)

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 1_500
    assert {:ok, {:noreply, _}} = Task.yield(task, 500)

    send(adapter_pid, {:release, gate_ref})
  end

  test "execute_stream callback is non-blocking" do
    state = base_state(GatedAdapter)
    from = {self(), make_ref()}
    callback_fn = fn _chunk -> :ok end
    gate_ref = make_ref()
    args = %{"test_pid" => self(), "gate_ref" => gate_ref}

    task =
      Task.async(fn ->
        GRPCWorker.handle_call(
          {:execute_stream, "ping", args, callback_fn, 1_000, []},
          from,
          state
        )
      end)

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 1_500
    assert {:ok, {:noreply, _}} = Task.yield(task, 500)

    send(adapter_pid, {:release, gate_ref})
  end

  test "execute_session callback is non-blocking" do
    state = base_state(GatedAdapter)
    from = {self(), make_ref()}
    gate_ref = make_ref()
    args = %{"test_pid" => self(), "gate_ref" => gate_ref}

    task =
      Task.async(fn ->
        GRPCWorker.handle_call(
          {:execute_session, "session_1", "ping", args, 1_000, []},
          from,
          state
        )
      end)

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 1_500
    assert {:ok, {:noreply, _}} = Task.yield(task, 500)

    send(adapter_pid, {:release, gate_ref})
  end

  test "get_health callback is non-blocking" do
    state = base_state(GatedAdapter)

    assert {:noreply, _state} = GRPCWorker.handle_call(:get_health, {self(), make_ref()}, state)
  end

  test "get_info callback is non-blocking" do
    state = base_state(GatedAdapter)

    assert {:noreply, _state} = GRPCWorker.handle_call(:get_info, {self(), make_ref()}, state)
  end

  test "periodic health check is routed through async RPC queue" do
    state = base_state(GatedAdapter)

    assert {:noreply, new_state} = GRPCWorker.handle_info(:health_check, state)
    assert map_size(new_state.pending_rpc_calls) == 1
    assert map_size(new_state.pending_rpc_monitors) == 1
  end

  test "periodic health check returns quickly while health RPC is delayed" do
    gate_ref = make_ref()
    test_pid = self()

    delayed_channel = %{
      mock: true,
      ping_fun: fn _message, _opts ->
        ping_pid = self()
        send(test_pid, {:health_ping_waiting, gate_ref, ping_pid})

        receive do
          {:release_health_ping, ^gate_ref} -> {:ok, %{message: "pong"}}
        after
          5_000 -> {:error, :gate_timeout}
        end
      end
    }

    state = base_state(GatedAdapter, delayed_channel)

    started_at = System.monotonic_time(:millisecond)
    assert {:noreply, queued_state} = GRPCWorker.handle_info(:health_check, state)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 100
    assert map_size(queued_state.pending_rpc_calls) == 1

    assert_receive {:health_ping_waiting, ^gate_ref, ping_pid}, 1_000
    send(ping_pid, {:release_health_ping, gate_ref})
  end

  test "get_info returns structured grpc_error when client call fails" do
    channel = %{mock: true, get_info_result: {:error, :transport_closed}}
    state = base_state(GatedAdapter, channel)
    from = {self(), make_ref()}
    tag = elem(from, 1)

    assert {:noreply, queued_state} = GRPCWorker.handle_call(:get_info, from, state)

    assert_receive {:grpc_async_rpc_result, token, {:ok, {reply, :none}}}, 1_000
    assert {:error, %Snakepit.Error{category: :grpc_error, grpc_status: :info_failed}} = reply

    assert {:noreply, _final_state} =
             GRPCWorker.handle_info(
               {:grpc_async_rpc_result, token, {:ok, {reply, :none}}},
               queued_state
             )

    assert_receive {^tag, ^reply}, 1_000
  end

  test "terminate cancels pending async RPC calls and replies waiting callers" do
    pending_from = {self(), make_ref()}
    pending_tag = elem(pending_from, 1)
    queued_from = {self(), make_ref()}
    queued_tag = elem(queued_from, 1)

    gate_ref = make_ref()

    task_pid =
      spawn(fn ->
        receive do
          {:release_pending_rpc, ^gate_ref} -> :ok
        end
      end)

    monitor_ref = Process.monitor(task_pid)
    token = make_ref()

    queued_request = %{from: queued_from, callback_fun: fn -> :ok end, otel_ctx: :undefined}

    state =
      base_state(GatedAdapter)
      |> Map.merge(%{
        ready_file:
          Path.join(
            System.tmp_dir!(),
            "snakepit_terminate_pending_rpc_#{System.unique_integer([:positive])}"
          ),
        heartbeat_monitor: nil,
        heartbeat_config: %{},
        server_port: nil,
        process_pid: nil,
        pending_rpc_calls: %{
          token => %{from: pending_from, monitor_ref: monitor_ref, task_pid: task_pid}
        },
        pending_rpc_monitors: %{monitor_ref => token},
        rpc_request_queue: :queue.in(queued_request, :queue.new())
      })

    assert :ok = GRPCWorker.terminate(:shutdown, state)

    assert_receive {^pending_tag, {:error, %Snakepit.Error{category: :worker}}}, 1_000
    assert_receive {^queued_tag, {:error, %Snakepit.Error{category: :worker}}}, 1_000

    refute Process.alive?(task_pid)
  end

  defp base_state(adapter, channel \\ :mock_channel) do
    %{
      adapter: adapter,
      connection: %{channel: channel},
      session_id: "session_1",
      id: "worker_1",
      pool_name: :default,
      health_check_ref: nil,
      stats: %{
        requests: 0,
        errors: 0,
        start_time: System.monotonic_time()
      },
      rpc_request_queue: :queue.new(),
      pending_rpc_calls: %{},
      pending_rpc_monitors: %{}
    }
  end
end
