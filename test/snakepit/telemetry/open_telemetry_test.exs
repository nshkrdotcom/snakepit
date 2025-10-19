defmodule Snakepit.Telemetry.OpenTelemetryTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Telemetry.OpenTelemetry
  alias Snakepit.TestAdapters.MockGRPCAdapter

  setup do
    original_config = Application.get_env(:snakepit, :opentelemetry)

    clean_env = %{
      enabled: true,
      debug_pid: self(),
      force?: true,
      skip_runtime?: true,
      exporters: %{
        otlp: %{enabled: false},
        console: %{enabled: false}
      }
    }

    Application.put_env(:snakepit, :opentelemetry, clean_env)
    :ok = OpenTelemetry.setup()

    on_exit(fn ->
      if original_config do
        Application.put_env(:snakepit, :opentelemetry, original_config)
      else
        Application.delete_env(:snakepit, :opentelemetry)
      end

      Application.put_env(:snakepit, :opentelemetry, %{enabled: false})
      :ok = OpenTelemetry.setup()
    end)

    :ok
  end

  test "bridges telemetry events for GRPC executions" do
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

    worker_id = "default_worker_otel_#{System.unique_integer([:positive])}"

    {:ok, starter_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        MockGRPCAdapter,
        Snakepit.Pool,
        %{heartbeat: %{enabled: false}}
      )

    assert is_pid(starter_pid)

    assert_eventually(
      fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
      timeout: 5_000,
      interval: 50
    )

    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)
    {:ok, _result} = Snakepit.GRPCWorker.execute(worker_pid, "ping", %{})

    start_meta = await_otel_event(:grpc_execute_start, worker_id, 1_000)
    assert start_meta.worker_id == worker_id

    {stop_meta, measurements} =
      await_otel_event(:grpc_execute_stop, worker_id, 1_000)

    assert stop_meta.worker_id == worker_id

    assert measurements[:executions] == 1
    assert measurements[:duration_ms] >= 0

    refute_receive {:snakepit_otel, {:grpc_execute_exception, _, _}}

    :ok = GenServer.stop(worker_pid)
  end

  defp await_otel_event(tag, worker_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_otel_event(tag, worker_id, deadline)
  end

  defp do_await_otel_event(tag, worker_id, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:snakepit_otel, {^tag, %{worker_id: ^worker_id} = meta}} ->
        meta

      {:snakepit_otel, {^tag, %{worker_id: ^worker_id} = meta, measurements}} ->
        {meta, measurements}

      {:snakepit_otel, _other} ->
        do_await_otel_event(tag, worker_id, deadline_ms)

      _other ->
        do_await_otel_event(tag, worker_id, deadline_ms)
    after
      remaining ->
        flunk("Timed out waiting for OpenTelemetry event #{inspect(tag)} for worker #{worker_id}")
    end
  end
end
