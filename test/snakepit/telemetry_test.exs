defmodule Snakepit.TelemetryTest do
  use ExUnit.Case
  alias Snakepit.Telemetry

  describe "telemetry setup" do
    test "attaches default handlers on setup" do
      # Get initial handler count
      initial_handlers = :telemetry.list_handlers()
      
      # Setup telemetry
      :ok = Telemetry.setup()
      
      # Should have more handlers now
      new_handlers = :telemetry.list_handlers()
      assert length(new_handlers) >= length(initial_handlers)
      
      # Verify snakepit handlers are attached
      snakepit_handlers = Enum.filter(new_handlers, fn handler ->
        String.starts_with?(Atom.to_string(handler.id), "snakepit-")
      end)
      
      assert length(snakepit_handlers) > 0
    end
  end

  describe "execution telemetry" do
    test "emits start event" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-start-#{inspect(ref)}",
        [:snakepit, :pool, :execution, :start],
        fn _event, measurements, metadata, _config ->
          send(self(), {:start_event, measurements, metadata})
        end,
        nil
      )
      
      metadata = %{command: "test", args: %{}, pool: TestPool}
      Telemetry.emit_start(:execution, metadata)
      
      assert_receive {:start_event, measurements, received_metadata}, 1000
      
      assert measurements.system_time > 0
      assert received_metadata.command == "test"
      assert received_metadata.pool == TestPool
      
      :telemetry.detach("test-start-#{inspect(ref)}")
    end

    test "emits stop event with duration" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-stop-#{inspect(ref)}",
        [:snakepit, :pool, :execution, :stop],
        fn _event, measurements, metadata, _config ->
          send(self(), {:stop_event, measurements, metadata})
        end,
        nil
      )
      
      start_time = System.monotonic_time()
      metadata = %{command: "test", success: true}
      
      Process.sleep(10) # Simulate some work
      
      Telemetry.emit_stop(:execution, start_time, metadata)
      
      assert_receive {:stop_event, measurements, received_metadata}, 1000
      
      assert measurements.duration > 0
      assert received_metadata.command == "test"
      assert received_metadata.success == true
      
      :telemetry.detach("test-stop-#{inspect(ref)}")
    end

    test "emits exception event" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-exception-#{inspect(ref)}",
        [:snakepit, :pool, :execution, :exception],
        fn _event, measurements, metadata, _config ->
          send(self(), {:exception_event, measurements, metadata})
        end,
        nil
      )
      
      start_time = System.monotonic_time()
      metadata = %{command: "test"}
      exception = %RuntimeError{message: "Test error"}
      
      Telemetry.emit_exception(:execution, start_time, exception, metadata)
      
      assert_receive {:exception_event, measurements, received_metadata}, 1000
      
      assert measurements.duration > 0
      assert received_metadata.command == "test"
      assert received_metadata.kind == :error
      assert received_metadata.reason == exception
      
      :telemetry.detach("test-exception-#{inspect(ref)}")
    end
  end

  describe "pool telemetry" do
    test "emits pool stats" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-pool-stats-#{inspect(ref)}",
        [:snakepit, :pool, :stats],
        fn _event, measurements, metadata, _config ->
          send(self(), {:pool_stats, measurements, metadata})
        end,
        nil
      )
      
      stats = %{
        total_workers: 5,
        available_workers: 3,
        busy_workers: 2,
        queued_requests: 1
      }
      
      Telemetry.emit_pool_stats(stats, %{pool: TestPool})
      
      assert_receive {:pool_stats, measurements, metadata}, 1000
      
      assert measurements.total_workers == 5
      assert measurements.available_workers == 3
      assert measurements.busy_workers == 2
      assert measurements.queued_requests == 1
      assert metadata.pool == TestPool
      
      :telemetry.detach("test-pool-stats-#{inspect(ref)}")
    end
  end

  describe "custom metrics" do
    test "allows custom metric emission" do
      ref = make_ref()
      
      :telemetry.attach(
        "test-custom-#{inspect(ref)}",
        [:snakepit, :custom, :metric],
        fn _event, measurements, metadata, _config ->
          send(self(), {:custom_metric, measurements, metadata})
        end,
        nil
      )
      
      :telemetry.execute(
        [:snakepit, :custom, :metric],
        %{value: 42, count: 10},
        %{metric_name: "test_metric"}
      )
      
      assert_receive {:custom_metric, measurements, metadata}, 1000
      
      assert measurements.value == 42
      assert measurements.count == 10
      assert metadata.metric_name == "test_metric"
      
      :telemetry.detach("test-custom-#{inspect(ref)}")
    end
  end
end