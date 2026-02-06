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

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 500
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

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 500
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

    assert_receive {:adapter_waiting, ^gate_ref, adapter_pid}, 500
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

  defp base_state(adapter) do
    %{
      adapter: adapter,
      connection: %{channel: :mock_channel},
      session_id: "session_1",
      id: "worker_1",
      pool_name: :default,
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
