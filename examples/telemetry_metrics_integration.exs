#!/usr/bin/env elixir

# Telemetry Metrics Integration Example
# Demonstrates how to integrate Snakepit telemetry with metrics systems
# like Prometheus, StatsD, and custom exporters
# Usage: elixir examples/telemetry_metrics_integration.exs

# Configure Snakepit for gRPC
Application.put_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)
Application.put_env(:snakepit, :pooling_enabled, true)

Application.put_env(:snakepit, :pools, [
  %{
    name: :default,
    worker_profile: :process,
    pool_size: 3,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 3})
Application.put_env(:snakepit, :grpc_port, 50051)

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

Mix.install([
  {:snakepit, path: "."},
  {:grpc, "~> 0.10.2"},
  {:protobuf, "~> 0.14.1"},
  {:telemetry_metrics, "~> 1.0"}
])

defmodule TelemetryMetricsExample do
  @moduledoc """
  Demonstrates integrating Snakepit telemetry with metrics systems.

  This example shows:
  1. Defining metrics using Telemetry.Metrics
  2. Custom metric exporter (simulated Prometheus)
  3. Real-time metrics visualization
  4. Common metric patterns (counters, gauges, histograms)
  """

  def run do
    IO.puts("\n=== Telemetry Metrics Integration Example ===\n")

    # Start custom metrics exporter
    exporter = start_metrics_exporter()

    # Setup metrics
    setup_metrics(exporter)

    IO.puts("✓ Metrics system initialized\n")
    IO.puts("Metrics being collected:")
    IO.puts("  - snakepit.python.call.duration (summary)")
    IO.puts("  - snakepit.python.call.count (counter)")
    IO.puts("  - snakepit.pool.queue_depth (gauge)")
    IO.puts("  - snakepit.pool.available_workers (gauge)")
    IO.puts("  - snakepit.error.count (counter)\n")

    # Run workload
    simulate_workload()

    # Display metrics
    display_metrics(exporter)

    IO.puts("\n=== Metrics Integration Example Complete ===\n")
    IO.puts("Integration Patterns:")
    IO.puts("  - Use telemetry_metrics for metric definitions")
    IO.puts("  - Prometheus: Use telemetry_metrics_prometheus")
    IO.puts("  - StatsD: Use telemetry_metrics_statsd")
    IO.puts("  - Custom: Attach handlers directly to telemetry events\n")
  end

  defp start_metrics_exporter do
    spawn(fn -> metrics_loop(%{}) end)
  end

  defp setup_metrics(exporter) do
    # Define metrics using Telemetry.Metrics
    metrics = [
      # Summary: Python call duration
      Telemetry.Metrics.summary(
        "snakepit.python.call.stop.duration",
        unit: {:native, :millisecond},
        tags: [:command]
      ),

      # Counter: Total calls
      Telemetry.Metrics.counter(
        "snakepit.python.call.stop.count",
        tags: [:command]
      ),

      # Counter: Errors
      Telemetry.Metrics.counter(
        "snakepit.python.call.exception.count",
        tags: [:command, :error_type]
      ),

      # Last value: Queue depth
      Telemetry.Metrics.last_value(
        "snakepit.pool.status.queue_depth",
        tags: [:pool_name]
      ),

      # Last value: Available workers
      Telemetry.Metrics.last_value(
        "snakepit.pool.status.available_workers",
        tags: [:pool_name]
      ),

      # Counter: Worker lifecycle
      Telemetry.Metrics.counter("snakepit.pool.worker.spawned.count")
    ]

    # Attach handlers for each metric
    attach_metric_handlers(metrics, exporter)
  end

  defp attach_metric_handlers(metrics, exporter) do
    Enum.each(metrics, fn metric ->
      handler_id = "metrics-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        metric.event_name,
        fn event, measurements, metadata, _config ->
          handle_metric_event(metric, event, measurements, metadata, exporter)
        end,
        nil
      )
    end)
  end

  defp handle_metric_event(metric, _event, measurements, metadata, exporter) do
    case metric.metric_type do
      :summary ->
        # Extract duration and convert to milliseconds
        value =
          measurements
          |> Map.get(List.last(metric.measurement || [:duration]))
          |> case do
            nil -> 0
            v -> v / 1_000_000
          end

        tags = extract_tags(metric.tags, metadata)
        send(exporter, {:summary, metric.name, value, tags})

      :counter ->
        tags = extract_tags(metric.tags, metadata)
        send(exporter, {:counter, metric.name, 1, tags})

      :last_value ->
        # Get the measurement value
        measurement_key = List.last(metric.measurement || [:value])
        value = Map.get(measurements, measurement_key, 0)
        tags = extract_tags(metric.tags, metadata)
        send(exporter, {:gauge, metric.name, value, tags})

      _ ->
        :ok
    end
  end

  defp extract_tags(tag_keys, metadata) do
    Enum.reduce(tag_keys, %{}, fn key, acc ->
      case Map.get(metadata, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp metrics_loop(state) do
    receive do
      {:summary, name, value, tags} ->
        key = {name, tags}

        updated =
          Map.update(state, key, %{values: [value], type: :summary}, fn existing ->
            %{existing | values: [value | existing.values]}
          end)

        metrics_loop(updated)

      {:counter, name, increment, tags} ->
        key = {name, tags}

        updated =
          Map.update(state, key, %{count: increment, type: :counter}, fn existing ->
            %{existing | count: existing.count + increment}
          end)

        metrics_loop(updated)

      {:gauge, name, value, tags} ->
        key = {name, tags}
        updated = Map.put(state, key, %{value: value, type: :gauge})
        metrics_loop(updated)

      {:get_metrics, pid} ->
        send(pid, {:metrics, state})
        metrics_loop(state)

      _ ->
        metrics_loop(state)
    end
  end

  defp simulate_workload do
    IO.puts("Simulating workload to generate metrics...\n")

    # Execute various commands
    commands = [
      {"ping", %{}},
      {"add", %{a: 5, b: 10}},
      {"echo", %{message: "test"}},
      {"telemetry_demo", %{operation: "test1", delay_ms: 50}},
      {"telemetry_demo", %{operation: "test2", delay_ms: 100}}
    ]

    for {command, params} <- commands do
      case Snakepit.execute(command, params) do
        {:ok, _} -> IO.puts("  ✓ #{command} executed")
        {:error, _} -> IO.puts("  ❌ #{command} failed")
      end

      Process.sleep(100)
    end

    # Execute some concurrent requests
    IO.puts("\n  Running concurrent requests...")

    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          Snakepit.execute("add", %{a: i, b: i * 2})
        end)
      end

    Task.await_many(tasks, 30_000)

    Process.sleep(200)
    IO.puts("  ✓ Workload complete\n")
  end

  defp display_metrics(exporter) do
    send(exporter, {:get_metrics, self()})

    receive do
      {:metrics, metrics} ->
        IO.puts("╔════════════════════════════════════════════════════════════════╗")
        IO.puts("║                  METRICS DASHBOARD                             ║")
        IO.puts("╠════════════════════════════════════════════════════════════════╣")

        # Group metrics by type
        summaries = Enum.filter(metrics, fn {_, v} -> v.type == :summary end)
        counters = Enum.filter(metrics, fn {_, v} -> v.type == :counter end)
        gauges = Enum.filter(metrics, fn {_, v} -> v.type == :gauge end)

        # Display summaries
        if !Enum.empty?(summaries) do
          IO.puts("║ Summary Metrics (Duration):                                    ║")

          Enum.each(summaries, fn {{name, tags}, data} ->
            values = data.values
            avg = Enum.sum(values) / length(values)
            min = Enum.min(values)
            max = Enum.max(values)
            count = length(values)

            short_name = name |> to_string() |> String.split(".") |> List.last()
            tag_str = format_tags(tags)

            IO.puts(
              "║   #{pad_left(short_name, 30)}#{tag_str}#{String.duplicate(" ", max(0, 24 - String.length(tag_str)))} ║"
            )

            IO.puts(
              "║     Count: #{pad_left(count, 10)}  Avg: #{pad_left(Float.round(avg, 2), 8)}ms          ║"
            )

            IO.puts(
              "║     Min: #{pad_left(Float.round(min, 2), 10)}ms Max: #{pad_left(Float.round(max, 2), 8)}ms          ║"
            )
          end)

          IO.puts("╠════════════════════════════════════════════════════════════════╣")
        end

        # Display counters
        if !Enum.empty?(counters) do
          IO.puts("║ Counter Metrics:                                               ║")

          Enum.each(counters, fn {{name, tags}, data} ->
            short_name = name |> to_string() |> String.split(".") |> List.last()
            tag_str = format_tags(tags)
            IO.puts("║   #{pad_left(short_name, 40)}#{tag_str}: #{pad_left(data.count, 10)} ║")
          end)

          IO.puts("╠════════════════════════════════════════════════════════════════╣")
        end

        # Display gauges
        if !Enum.empty?(gauges) do
          IO.puts("║ Gauge Metrics (Last Value):                                    ║")

          Enum.each(gauges, fn {{name, tags}, data} ->
            short_name = name |> to_string() |> String.split(".") |> List.last()
            tag_str = format_tags(tags)
            IO.puts("║   #{pad_left(short_name, 40)}#{tag_str}: #{pad_left(data.value, 10)} ║")
          end)

          IO.puts("╠════════════════════════════════════════════════════════════════╣")
        end

        IO.puts("║                                                                ║")
        IO.puts("║ Prometheus Format Example:                                     ║")
        IO.puts("║   # TYPE snakepit_python_call_duration_ms summary              ║")
        IO.puts("║   snakepit_python_call_duration_ms{command=\"add\"} 45.2        ║")
        IO.puts("║   # TYPE snakepit_python_call_count counter                    ║")
        IO.puts("║   snakepit_python_call_count{command=\"add\"} 5                 ║")
        IO.puts("╚════════════════════════════════════════════════════════════════╝")
    after
      1000 -> IO.puts("⚠️  Timeout retrieving metrics")
    end
  end

  defp format_tags(tags) when map_size(tags) == 0, do: ""

  defp format_tags(tags) do
    tags
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(",")
    |> then(fn s -> "{#{s}}" end)
  end

  defp pad_left(value, width) do
    str = to_string(value)
    padding = max(0, width - String.length(str))
    String.duplicate(" ", padding) <> str
  end
end

defmodule TelemetryMetricsExample.PrometheusGuide do
  @moduledoc """
  Guide for integrating with real Prometheus exporter.
  """

  def show_integration_guide do
    IO.puts("""

    ╔════════════════════════════════════════════════════════════════╗
    ║        PROMETHEUS INTEGRATION GUIDE                            ║
    ╠════════════════════════════════════════════════════════════════╣
    ║                                                                ║
    ║ 1. Add to mix.exs:                                             ║
    ║    {:telemetry_metrics_prometheus, "~> 1.1"}                   ║
    ║                                                                ║
    ║ 2. In your application.ex:                                     ║
    ║                                                                ║
    ║    def start(_type, _args) do                                  ║
    ║      children = [                                              ║
    ║        # ... other children                                    ║
    ║        {TelemetryMetricsPrometheus,                            ║
    ║         metrics: metrics(), port: 9568}                        ║
    ║      ]                                                         ║
    ║      Supervisor.start_link(children, strategy: :one_for_one)  ║
    ║    end                                                         ║
    ║                                                                ║
    ║    defp metrics do                                             ║
    ║      [                                                         ║
    ║        summary("snakepit.python.call.stop.duration",          ║
    ║          unit: {:native, :millisecond},                        ║
    ║          tags: [:command]),                                    ║
    ║        counter("snakepit.python.call.exception.count",        ║
    ║          tags: [:error_type]),                                 ║
    ║        last_value("snakepit.pool.status.queue_depth")         ║
    ║      ]                                                         ║
    ║    end                                                         ║
    ║                                                                ║
    ║ 3. Access metrics at: http://localhost:9568/metrics           ║
    ║                                                                ║
    ║ 4. Configure Prometheus to scrape the endpoint                ║
    ║                                                                ║
    ╠════════════════════════════════════════════════════════════════╣
    ║        STATSD INTEGRATION                                      ║
    ╠════════════════════════════════════════════════════════════════╣
    ║                                                                ║
    ║ 1. Add to mix.exs:                                             ║
    ║    {:telemetry_metrics_statsd, "~> 0.7"}                      ║
    ║                                                                ║
    ║ 2. In your application.ex:                                     ║
    ║                                                                ║
    ║    {TelemetryMetricsStatsd,                                    ║
    ║     metrics: metrics(),                                        ║
    ║     host: "statsd.local",                                      ║
    ║     port: 8125}                                                ║
    ║                                                                ║
    ╠════════════════════════════════════════════════════════════════╣
    ║        CUSTOM HANDLERS                                         ║
    ╠════════════════════════════════════════════════════════════════╣
    ║                                                                ║
    ║ For custom integrations, attach directly:                     ║
    ║                                                                ║
    ║    :telemetry.attach(                                          ║
    ║      "my-custom-handler",                                      ║
    ║      [:snakepit, :python, :call, :stop],                      ║
    ║      &MyApp.handle_metric/4,                                   ║
    ║      nil                                                       ║
    ║    )                                                           ║
    ║                                                                ║
    ╚════════════════════════════════════════════════════════════════╝
    """)
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  TelemetryMetricsExample.run()
  TelemetryMetricsExample.PrometheusGuide.show_integration_guide()
end)
