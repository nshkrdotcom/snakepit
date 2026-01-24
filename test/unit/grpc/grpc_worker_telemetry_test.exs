defmodule Snakepit.GRPCWorkerTelemetryTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.TestAdapters.MockGRPCAdapter

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    Application.load(:snakepit)
    configure_pooling()

    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

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

      {:ok, worker_pid} =
        WorkerSupervisor.start_worker(
          worker_id,
          Snakepit.GRPCWorker,
          MockGRPCAdapter,
          Snakepit.Pool,
          worker_config
        )

      assert is_pid(worker_pid)

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

  defp configure_pooling do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: MockGRPCAdapter
      }
    ])

    Application.put_env(:snakepit, :adapter_module, MockGRPCAdapter)
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
