defmodule Snakepit.Telemetry.SpanTest do
  use ExUnit.Case, async: true

  alias Snakepit.Telemetry.Span

  describe "span/3" do
    test "wraps function and emits start/stop events" do
      event = [:test, :operation]
      parent = self()

      ref = make_ref()

      :telemetry.attach_many(
        "span-test-#{inspect(ref)}",
        [
          [:test, :operation, :start],
          [:test, :operation, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      result =
        Span.span(event, %{pool: :default}, fn ->
          {:ok, :success}
        end)

      assert result == {:ok, :success}

      # Check start event
      assert_receive {:telemetry, [:test, :operation, :start], start_measurements, start_meta}
      assert is_integer(start_measurements.system_time)
      assert start_meta.pool == :default

      # Check stop event
      assert_receive {:telemetry, [:test, :operation, :stop], stop_measurements, stop_meta}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_meta.pool == :default

      :telemetry.detach("span-test-#{inspect(ref)}")
    end

    test "emits exception event on error" do
      event = [:test, :failing]
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "span-exception-test-#{inspect(ref)}",
        [:test, :failing, :exception],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      catch_throw(
        Span.span(event, %{}, fn ->
          throw(:test_error)
        end)
      )

      assert_receive {:telemetry, [:test, :failing, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.kind == :throw
      assert metadata.reason == :test_error

      :telemetry.detach("span-exception-test-#{inspect(ref)}")
    end

    test "re-raises exceptions after emitting event" do
      event = [:test, :reraise]

      assert_raise RuntimeError, "test error", fn ->
        Span.span(event, %{}, fn ->
          raise "test error"
        end)
      end
    end
  end

  describe "start_span/2" do
    test "returns span reference" do
      event = [:test, :manual]
      span_ref = Span.start_span(event, %{foo: :bar})

      assert is_map(span_ref)
      assert span_ref.event == event
      assert is_integer(span_ref.start_time)
      assert span_ref.metadata.foo == :bar
    end
  end

  describe "end_span/1" do
    test "emits stop event with duration" do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "span-end-test-#{inspect(ref)}",
        [:test, :manual, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      event = [:test, :manual]
      span_ref = Span.start_span(event, %{key: :value})
      Span.end_span(span_ref)

      assert_receive {:telemetry, [:test, :manual, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.key == :value

      :telemetry.detach("span-end-test-#{inspect(ref)}")
    end
  end

  describe "end_span/2 with additional metadata" do
    test "merges additional metadata" do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "span-end-meta-test-#{inspect(ref)}",
        [:test, :meta, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      event = [:test, :meta]
      span_ref = Span.start_span(event, %{original: true})
      Span.end_span(span_ref, %{added: true, result: :success})

      assert_receive {:telemetry, [:test, :meta, :stop], _measurements, metadata}
      assert metadata.original == true
      assert metadata.added == true
      assert metadata.result == :success

      :telemetry.detach("span-end-meta-test-#{inspect(ref)}")
    end
  end
end
