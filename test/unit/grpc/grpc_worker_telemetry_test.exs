defmodule Snakepit.GRPCWorkerTelemetryTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.TestAdapters.MockGRPCAdapter

  describe "telemetry instrumentation" do
    test "emits telemetry events with correlation id on execute" do
      handler_id = "test-grpc-worker-telemetry"
      parent = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:snakepit, :grpc_worker, :execute, :start],
            [:snakepit, :grpc_worker, :execute, :stop]
          ],
          fn event, measurements, metadata, _ ->
            send(parent, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      worker_id = "default_worker_telemetry_#{System.unique_integer([:positive])}"

      worker_config = %{
        test_pid: self(),
        heartbeat: %{enabled: false}
      }

      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

      {:ok, starter_pid} =
        WorkerSupervisor.start_worker(
          worker_id,
          Snakepit.GRPCWorker,
          MockGRPCAdapter,
          Snakepit.Pool,
          worker_config
        )

      assert is_pid(starter_pid)

      assert_eventually(
        fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
        timeout: 5_000,
        interval: 50
      )

      {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)

      {:ok, _result} = Snakepit.GRPCWorker.execute(worker_pid, "ping", %{})

      {_start_measurements, start_meta} =
        await_worker_event(
          worker_id,
          [:snakepit, :grpc_worker, :execute, :start],
          2_000
        )

      assert is_binary(start_meta.correlation_id)
      refute start_meta.correlation_id == ""

      {measurements, stop_meta} =
        await_worker_event(
          worker_id,
          [:snakepit, :grpc_worker, :execute, :stop],
          2_000
        )

      assert stop_meta.correlation_id == start_meta.correlation_id
      assert measurements[:duration_ms] >= 0
      assert measurements[:executions] == 1

      :ok = GenServer.stop(worker_pid)
    end
  end

  defp await_worker_event(worker_id, event, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_worker_event(worker_id, event, deadline)
  end

  defp do_await_worker_event(worker_id, event, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry_event, ^event, measurements, %{worker_id: ^worker_id} = metadata} ->
        {measurements, metadata}

      {:telemetry_event, _other_event, _measurements, _metadata} ->
        do_await_worker_event(worker_id, event, deadline_ms)

      _other ->
        do_await_worker_event(worker_id, event, deadline_ms)
    after
      remaining ->
        flunk("Timed out waiting for telemetry event #{inspect(event)} for worker #{worker_id}")
    end
  end
end
