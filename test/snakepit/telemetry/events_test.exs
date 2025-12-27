defmodule Snakepit.Telemetry.EventsTest do
  use ExUnit.Case, async: true

  alias Snakepit.Telemetry.Events

  describe "hardware_events/0" do
    test "returns list of hardware-related events" do
      events = Events.hardware_events()

      assert is_list(events)

      Enum.each(events, fn event ->
        assert is_list(event)
        assert [:snakepit, :hardware | _] = event
      end)
    end

    test "includes detection events" do
      events = Events.hardware_events()

      assert [:snakepit, :hardware, :detect, :start] in events
      assert [:snakepit, :hardware, :detect, :stop] in events
    end
  end

  describe "circuit_breaker_events/0" do
    test "returns list of circuit breaker events" do
      events = Events.circuit_breaker_events()

      assert is_list(events)

      Enum.each(events, fn event ->
        assert is_list(event)
        assert [:snakepit, :circuit_breaker | _] = event
      end)
    end

    test "includes state transition events" do
      events = Events.circuit_breaker_events()

      assert [:snakepit, :circuit_breaker, :opened] in events
      assert [:snakepit, :circuit_breaker, :closed] in events
      assert [:snakepit, :circuit_breaker, :half_open] in events
    end
  end

  describe "exception_events/0" do
    test "returns list of exception events" do
      events = Events.exception_events()

      assert is_list(events)

      Enum.each(events, fn event ->
        assert is_list(event)
        assert [:snakepit | _] = event
      end)
    end

    test "includes shape error events" do
      events = Events.exception_events()

      assert [:snakepit, :error, :shape_mismatch] in events
      assert [:snakepit, :error, :device] in events
    end
  end

  describe "gpu_profiler_events/0" do
    test "returns list of GPU profiler events" do
      events = Events.gpu_profiler_events()

      assert is_list(events)

      Enum.each(events, fn event ->
        assert is_list(event)
        assert [:snakepit, :gpu | _] = event
      end)
    end

    test "includes memory sample event" do
      events = Events.gpu_profiler_events()

      assert [:snakepit, :gpu, :memory, :sampled] in events
    end
  end

  describe "all_ml_events/0" do
    test "returns all ML-related events" do
      events = Events.all_ml_events()

      assert is_list(events)
      # Should include hardware, circuit breaker, exception, and GPU events
      assert length(events) > 10
    end

    test "events are unique" do
      events = Events.all_ml_events()

      assert length(events) == length(Enum.uniq(events))
    end
  end

  describe "event_schema/1" do
    test "returns schema for known event" do
      schema = Events.event_schema([:snakepit, :hardware, :detect, :stop])

      assert is_map(schema)
      assert Map.has_key?(schema, :measurements)
      assert Map.has_key?(schema, :metadata)
    end

    test "returns nil for unknown event" do
      assert nil == Events.event_schema([:unknown, :event])
    end

    test "schema has valid measurement types" do
      schema = Events.event_schema([:snakepit, :hardware, :detect, :stop])

      Enum.each(schema.measurements, fn {_name, type} ->
        assert type in [:integer, :float, :monotonic_time, :system_time]
      end)
    end

    test "schema has valid metadata types" do
      schema = Events.event_schema([:snakepit, :gpu, :memory, :sampled])

      Enum.each(schema.metadata, fn {_name, type} ->
        assert type in [:string, :atom, :integer, :float, :map, :list, :any]
      end)
    end
  end
end
