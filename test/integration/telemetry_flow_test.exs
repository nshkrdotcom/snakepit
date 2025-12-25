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
  test "worker spawned event is emitted" do
    # Note: This test is skipped by default because it requires pooling to be enabled
    # Run with: mix test --include skip test/integration/telemetry_flow_test.exs

    # Wait for worker spawned event
    assert_receive {:telemetry, [:snakepit, :pool, :worker, :spawned], measurements, metadata},
                   5_000

    # Verify measurements
    assert is_integer(measurements.duration)
    assert measurements.duration >= 0
    assert is_integer(measurements.system_time)

    # Verify metadata
    assert metadata.node == node()
    assert is_atom(metadata.pool_name) or is_pid(metadata.pool_name)
    assert is_binary(metadata.worker_id)
    assert is_pid(metadata.worker_pid)
    assert metadata.mode == :process
  end

  @tag :skip
  test "python telemetry events are received from showcase adapter" do
    # Note: This test is skipped by default because it requires a running pool
    # Run with: mix test --include skip test/integration/telemetry_flow_test.exs

    # This test would execute the telemetry_demo tool and verify events are received
    # Requires setup: {:ok, worker} = Snakepit.Pool.checkout()
    # Then: Snakepit.GRPCWorker.execute(worker, "telemetry_demo", %{operation: "test"})

    # For now, this is a placeholder showing the expected flow:
    # 1. Execute telemetry_demo tool
    # 2. Receive [:snakepit, :python, :tool, :execution, :start]
    # 3. Receive [:snakepit, :python, :tool, :result_size]
    # 4. Receive [:snakepit, :python, :tool, :execution, :stop]

    flunk("Test not yet implemented - requires running pool")
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
end
