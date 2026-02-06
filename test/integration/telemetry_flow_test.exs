defmodule Snakepit.Integration.TelemetryFlowTest do
  use ExUnit.Case, async: false

  alias Snakepit.Bridge.TelemetryEventFilter
  alias Snakepit.Bridge.TelemetrySamplingUpdate
  alias Snakepit.Bridge.TelemetryToggle
  alias Snakepit.Telemetry.Control
  alias Snakepit.Telemetry.GrpcStream
  alias Snakepit.Telemetry.Naming
  alias Snakepit.Telemetry.SafeMetadata

  @moduletag :integration
  @moduletag timeout: 60_000

  require Logger

  setup do
    # Attach a test telemetry handler to capture events
    test_pid = self()

    :telemetry.attach_many(
      "telemetry-flow-test",
      [
        [:snakepit, :pool, :worker, :spawned],
        [:snakepit, :pool, :worker, :terminated],
        [:snakepit, :python, :tool, :execution, :start],
        [:snakepit, :python, :tool, :execution, :stop],
        [:snakepit, :python, :tool, :result_size]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("telemetry-flow-test")
    end)

    :ok
  end

  @tag :skip
  @tag :python_integration
  test "worker spawned event is emitted" do
    with_python_pool(fn ->
      {measurements, metadata} =
        await_telemetry_event(
          [:snakepit, :pool, :worker, :spawned],
          20_000,
          fn _measurements, metadata ->
            is_binary(metadata[:worker_id]) and metadata[:mode] == :process
          end
        )

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert is_integer(measurements.system_time)

      assert metadata.node == node()
      assert is_atom(metadata.pool_name) or is_pid(metadata.pool_name)
      assert is_binary(metadata.worker_id)
      assert is_pid(metadata.worker_pid)
      assert metadata.mode == :process
    end)
  end

  @tag :skip
  @tag :python_integration
  test "python telemetry events are received from showcase adapter" do
    with_python_pool(fn ->
      :ok = await_telemetry_stream(10_000)

      assert {:ok,
              %{
                "message" =>
                  "Telemetry events emitted successfully! Check Elixir :telemetry handlers.",
                "telemetry_enabled" => true
              }} =
               Snakepit.execute(
                 "telemetry_demo",
                 %{"operation" => "telemetry_flow_test", "delay_ms" => 10},
                 timeout: 30_000
               )

      {start_measurements, start_metadata} =
        await_telemetry_event(
          [:snakepit, :python, :tool, :execution, :start],
          10_000,
          fn _measurements, metadata ->
            metadata[:tool] == "telemetry_demo" and metadata[:operation] == "telemetry_flow_test"
          end
        )

      assert is_integer(start_measurements.system_time)
      assert start_measurements.system_time > 0
      assert start_metadata.tool == "telemetry_demo"
      assert start_metadata.operation == "telemetry_flow_test"
      assert is_binary(start_metadata.correlation_id)
      refute start_metadata.correlation_id == ""

      {size_measurements, size_metadata} =
        await_telemetry_event(
          [:snakepit, :python, :tool, :result_size],
          10_000,
          fn _measurements, metadata -> metadata[:tool] == "telemetry_demo" end
        )

      bytes = Map.get(size_measurements, :bytes, Map.get(size_measurements, :message_size))
      assert is_integer(bytes)
      assert bytes > 0
      assert size_metadata.tool == "telemetry_demo"

      {stop_measurements, stop_metadata} =
        await_telemetry_event(
          [:snakepit, :python, :tool, :execution, :stop],
          10_000,
          fn _measurements, metadata ->
            metadata[:tool] == "telemetry_demo" and metadata[:operation] == "telemetry_flow_test"
          end
        )

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.correlation_id == start_metadata.correlation_id
    end)
  end

  test "telemetry event catalog is complete" do
    # Verify all expected events are defined
    events = Snakepit.Telemetry.events()

    # Check we have events from all layers
    assert Enum.any?(events, fn event -> event == [:snakepit, :pool, :worker, :spawned] end)
    assert Enum.any?(events, fn event -> event == [:snakepit, :python, :call, :start] end)
    assert Enum.any?(events, fn event -> event == [:snakepit, :grpc, :call, :start] end)

    # Verify total count (should have 40+ events across all layers)
    assert length(events) > 40
  end

  test "telemetry naming module validates event parts" do
    # Test valid Python event
    assert {:ok, [:snakepit, :python, :call, :start]} =
             Naming.from_parts(["python", "call", "start"])

    # Test invalid event
    assert {:error, :unknown_event} =
             Naming.from_parts(["invalid", "event"])

    # Test tool execution events
    assert {:ok, [:snakepit, :python, :tool, :execution, :start]} =
             Naming.from_parts(["tool", "execution", "start"])
  end

  test "telemetry safe metadata sanitizes input" do
    # Test that unknown keys remain as strings (atom safety)
    {:ok, metadata} =
      SafeMetadata.sanitize(%{
        "node" => "test@localhost",
        "unknown_key" => "value"
      })

    # Known key should be atom
    assert metadata.node == "test@localhost"

    # Unknown key should remain string
    assert metadata["unknown_key"] == "value"
  end

  test "telemetry measurement keys are validated" do
    # Valid measurement key
    assert {:ok, :duration} = Naming.measurement_key("duration")

    # Invalid measurement key
    assert {:error, :unknown_measurement_key} =
             Naming.measurement_key("invalid_key")
  end

  test "telemetry control messages are built correctly" do
    # Test toggle
    toggle = Control.toggle(true)
    assert toggle.control == {:toggle, %TelemetryToggle{enabled: true}}

    # Test sampling
    sampling = Control.sampling(0.5, ["python.call.*"])

    assert sampling.control ==
             {:sampling,
              %TelemetrySamplingUpdate{
                sampling_rate: 0.5,
                event_patterns: ["python.call.*"]
              }}

    # Test filter
    filter = Control.filter(allow: ["python.*"])

    assert filter.control ==
             {:filter,
              %TelemetryEventFilter{
                allow: ["python.*"],
                deny: []
              }}
  end

  test "telemetry grpc stream manager can list streams" do
    # This should work even without active streams
    streams = GrpcStream.list_streams()
    assert is_list(streams)
  end

  defp with_python_pool(fun) when is_function(fun, 0) do
    prev_env = capture_env()
    stop_snakepit_and_wait()
    configure_python_pool()
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 60_000)

    try do
      fun.()
    after
      stop_snakepit_and_wait()
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end
  end

  defp await_telemetry_event(event, timeout_ms, matcher_fn)
       when is_list(event) and is_integer(timeout_ms) and timeout_ms > 0 and
              is_function(matcher_fn, 2) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_telemetry_event(event, deadline, matcher_fn)
  end

  defp do_await_telemetry_event(event, deadline, matcher_fn) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry, ^event, measurements, metadata} ->
        if matcher_fn.(measurements, metadata) do
          {measurements, metadata}
        else
          do_await_telemetry_event(event, deadline, matcher_fn)
        end

      {:telemetry, _other_event, _measurements, _metadata} ->
        do_await_telemetry_event(event, deadline, matcher_fn)

      _other ->
        do_await_telemetry_event(event, deadline, matcher_fn)
    after
      remaining ->
        flunk("Timed out waiting for telemetry event #{inspect(event)}")
    end
  end

  defp await_telemetry_stream(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_telemetry_stream(deadline)
  end

  defp do_await_telemetry_stream(deadline) do
    stream_ready? =
      GrpcStream.list_streams()
      |> Enum.any?(fn stream ->
        stream[:task_alive] == true
      end)

    if stream_ready? do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("Timed out waiting for telemetry stream registration")
      else
        wait_ms = min(remaining, 100)
        Process.sleep(wait_ms)
        do_await_telemetry_stream(deadline)
      end
    end
  end

  defp configure_python_pool do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})
    Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: Snakepit.Adapters.GRPCPython
      }
    ])
  end

  defp stop_snakepit_and_wait do
    sup_pid = Process.whereis(Snakepit.Supervisor)
    sup_ref = if sup_pid && Process.alive?(sup_pid), do: Process.monitor(sup_pid)

    Application.stop(:snakepit)

    if sup_ref do
      receive do
        {:DOWN, ^sup_ref, :process, ^sup_pid, _reason} ->
          :ok
      after
        10_000 ->
          flunk("Timed out waiting for Snakepit supervisor to terminate")
      end
    end
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
