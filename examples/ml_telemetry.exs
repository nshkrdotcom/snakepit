#!/usr/bin/env elixir

# ML Telemetry Example
# Demonstrates ML-specific telemetry including hardware detection events,
# GPU profiling, span timing, and metrics for Prometheus integration.
#
# Usage: mix run examples/ml_telemetry.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule MLTelemetryExample do
  @moduledoc """
  Demonstrates Snakepit's ML telemetry and observability features.
  """

  alias Snakepit.Telemetry.{Events, Span}
  alias Snakepit.Telemetry.Handlers.{Logger, Metrics}

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  ML Telemetry and Observability")
    IO.puts(String.duplicate("=", 60) <> "\n")

    demo_event_catalog()
    demo_telemetry_handlers()
    demo_span_timing()
    demo_metrics_definitions()
    demo_manual_events()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  ML Telemetry Demo Complete!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  defp demo_event_catalog do
    IO.puts("1. ML Telemetry Event Catalog")
    IO.puts(String.duplicate("-", 40))

    IO.puts("   Available event categories:\n")

    # Hardware events
    hardware_events = Events.hardware_events()
    IO.puts("   Hardware Events (#{length(hardware_events)}):")

    for event <- hardware_events do
      IO.puts("   - #{format_event(event)}")
    end

    # Exception events
    exception_events = Events.exception_events()
    IO.puts("\n   Exception Events (#{length(exception_events)}):")

    for event <- exception_events do
      IO.puts("   - #{format_event(event)}")
    end

    # Circuit breaker events
    cb_events = Events.circuit_breaker_events()
    IO.puts("\n   Circuit Breaker Events (#{length(cb_events)}):")

    for event <- cb_events do
      IO.puts("   - #{format_event(event)}")
    end

    # GPU events
    gpu_events = Events.gpu_profiler_events()
    IO.puts("\n   GPU Profiler Events (#{length(gpu_events)}):")

    for event <- gpu_events do
      IO.puts("   - #{format_event(event)}")
    end

    # Total count
    all_events = Events.all_ml_events()
    IO.puts("\n   Total ML events defined: #{length(all_events)}")

    IO.puts("")
  end

  defp demo_telemetry_handlers do
    IO.puts("2. Telemetry Logger Handler")
    IO.puts(String.duplicate("-", 40))

    # Ensure telemetry is started
    {:ok, _} = Application.ensure_all_started(:telemetry)

    IO.puts("   Attaching logger handler for ML events...")

    # Attach the logger handler
    Logger.attach()
    IO.puts("   Logger handler attached!")

    # Emit some test events
    IO.puts("\n   Emitting test events (check logs):\n")

    # Hardware detection event
    :telemetry.execute(
      [:snakepit, :hardware, :detect, :stop],
      %{duration: 5_000_000},
      %{accelerator: :cuda, platform: "linux-x86_64"}
    )

    IO.puts("   - Emitted: hardware.detect.stop")

    # Circuit breaker event
    :telemetry.execute(
      [:snakepit, :circuit_breaker, :opened],
      %{failure_count: 5},
      %{pool: :ml_pool}
    )

    IO.puts("   - Emitted: circuit_breaker.opened")

    # Error event
    :telemetry.execute(
      [:snakepit, :error, :shape_mismatch],
      %{},
      %{expected: [3, 224, 224], got: [3, 256, 256], operation: "conv2d"}
    )

    IO.puts("   - Emitted: error.shape_mismatch")

    # Detach the handler
    Logger.detach()
    IO.puts("\n   Logger handler detached.")

    IO.puts("")
  end

  defp demo_span_timing do
    IO.puts("3. Span Timing Helper")
    IO.puts(String.duplicate("-", 40))

    IO.puts("   Setting up span event listener...")

    # Attach a handler to capture span events
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      "span-demo-#{inspect(ref)}",
      [:demo, :operation, :stop],
      fn event, measurements, metadata, _config ->
        send(parent, {:span_event, event, measurements, metadata})
      end,
      nil
    )

    # Use automatic span
    IO.puts("\n   a) Automatic span (wraps function):")

    result =
      Span.span([:demo, :operation], %{input_size: 1024}, fn ->
        # Simulate work
        Process.sleep(50)
        {:ok, "computed result"}
      end)

    IO.puts("      Result: #{inspect(result)}")

    receive do
      {:span_event, _event, measurements, metadata} ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
        IO.puts("      Duration: #{duration_ms}ms")
        IO.puts("      Metadata: input_size=#{metadata.input_size}")
    after
      1000 -> IO.puts("      (no event received)")
    end

    # Use manual span
    IO.puts("\n   b) Manual span (explicit start/end):")

    # Attach handler for manual span
    :telemetry.attach(
      "span-manual-#{inspect(ref)}",
      [:demo, :manual_op, :stop],
      fn event, measurements, metadata, _config ->
        send(parent, {:manual_span, event, measurements, metadata})
      end,
      nil
    )

    span_ref = Span.start_span([:demo, :manual_op], %{batch_size: 32})
    IO.puts("      Span started (ref: #{inspect(span_ref)})")

    # Simulate some work
    Process.sleep(30)

    Span.end_span(span_ref, %{items_processed: 32})
    IO.puts("      Span ended")

    receive do
      {:manual_span, _event, measurements, metadata} ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
        IO.puts("      Duration: #{duration_ms}ms")

        IO.puts(
          "      Metadata: batch_size=#{metadata.batch_size}, items_processed=#{metadata.items_processed}"
        )
    after
      1000 -> IO.puts("      (no event received)")
    end

    # Cleanup
    :telemetry.detach("span-demo-#{inspect(ref)}")
    :telemetry.detach("span-manual-#{inspect(ref)}")

    IO.puts("")
  end

  defp demo_metrics_definitions do
    IO.puts("4. Prometheus-Compatible Metrics")
    IO.puts(String.duplicate("-", 40))

    # Get metric definitions
    metrics = Metrics.definitions()

    IO.puts("   Available metrics for Prometheus integration:\n")

    # Group by type
    summaries = Enum.filter(metrics, &match?(%Telemetry.Metrics.Summary{}, &1))
    counters = Enum.filter(metrics, &match?(%Telemetry.Metrics.Counter{}, &1))
    last_values = Enum.filter(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1))

    IO.puts("   Summaries (#{length(summaries)}):")

    for metric <- Enum.take(summaries, 5) do
      IO.puts("   - #{format_metric_name(metric)}")
    end

    if length(summaries) > 5 do
      IO.puts("   - ... and #{length(summaries) - 5} more")
    end

    IO.puts("\n   Counters (#{length(counters)}):")

    for metric <- Enum.take(counters, 5) do
      IO.puts("   - #{format_metric_name(metric)}")
    end

    if length(counters) > 5 do
      IO.puts("   - ... and #{length(counters) - 5} more")
    end

    IO.puts("\n   Last Values (#{length(last_values)}):")

    for metric <- Enum.take(last_values, 5) do
      IO.puts("   - #{format_metric_name(metric)}")
    end

    if length(last_values) > 5 do
      IO.puts("   - ... and #{length(last_values) - 5} more")
    end

    IO.puts("\n   Total metrics: #{length(metrics)}")

    IO.puts("\n   To use with TelemetryMetricsPrometheus:")
    IO.puts("   ```")
    IO.puts("   children = [")
    IO.puts("     {TelemetryMetricsPrometheus,")
    IO.puts("      metrics: Snakepit.Telemetry.Handlers.Metrics.definitions()}")
    IO.puts("   ]")
    IO.puts("   ```")

    IO.puts("")
  end

  defp demo_manual_events do
    IO.puts("5. Emitting Custom ML Events")
    IO.puts(String.duplicate("-", 40))

    IO.puts("   Setting up custom event handlers...")

    parent = self()
    ref = make_ref()

    # Attach handlers for custom events
    :telemetry.attach(
      "custom-gpu-#{inspect(ref)}",
      [:snakepit, :gpu, :memory, :sampled],
      fn _event, measurements, metadata, _config ->
        send(parent, {:gpu_sample, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "custom-retry-#{inspect(ref)}",
      [:snakepit, :retry, :attempt],
      fn _event, measurements, metadata, _config ->
        send(parent, {:retry_attempt, measurements, metadata})
      end,
      nil
    )

    # Emit GPU memory sample event
    IO.puts("\n   Emitting GPU memory sample:")

    :telemetry.execute(
      [:snakepit, :gpu, :memory, :sampled],
      %{used_mb: 4096, total_mb: 8192, free_mb: 4096},
      %{device: {:cuda, 0}}
    )

    receive do
      {:gpu_sample, measurements, metadata} ->
        percent = Float.round(measurements.used_mb / measurements.total_mb * 100, 1)
        IO.puts("   - Device: #{inspect(metadata.device)}")

        IO.puts(
          "   - Memory: #{measurements.used_mb}/#{measurements.total_mb} MB (#{percent}% used)"
        )
    after
      1000 -> IO.puts("   (no event received)")
    end

    # Emit retry attempt event
    IO.puts("\n   Emitting retry attempt:")

    :telemetry.execute(
      [:snakepit, :retry, :attempt],
      %{attempt: 2, delay_ms: 200},
      %{pool: :ml_pool, operation: "model_inference"}
    )

    receive do
      {:retry_attempt, measurements, metadata} ->
        IO.puts("   - Pool: #{metadata.pool}")
        IO.puts("   - Attempt: #{measurements.attempt} (delay: #{measurements.delay_ms}ms)")
    after
      1000 -> IO.puts("   (no event received)")
    end

    # Cleanup
    :telemetry.detach("custom-gpu-#{inspect(ref)}")
    :telemetry.detach("custom-retry-#{inspect(ref)}")

    IO.puts("")
  end

  defp format_event(event) when is_list(event) do
    event |> Enum.map(&to_string/1) |> Enum.join(".")
  end

  defp format_metric_name(%{name: name}) when is_list(name) do
    name |> Enum.map(&to_string/1) |> Enum.join(".")
  end

  defp format_metric_name(%{event_name: event_name}) when is_list(event_name) do
    event_name |> Enum.map(&to_string/1) |> Enum.join(".")
  end

  defp format_metric_name(_), do: "unknown"
end

# Run the example
MLTelemetryExample.run()
