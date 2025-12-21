#!/usr/bin/env elixir

# Advanced Telemetry Example
# Demonstrates advanced telemetry features including runtime control,
# correlation IDs, performance monitoring, and multiple event patterns
# Usage: mix run --no-start examples/telemetry_advanced.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

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
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

defmodule TelemetryAdvancedExample do
  @moduledoc """
  Demonstrates advanced telemetry features:
  1. Runtime telemetry control (sampling, toggling)
  2. Correlation ID tracking across boundaries
  3. Performance monitoring and alerting
  4. Multiple event patterns (attach_many)
  5. Custom metrics aggregation
  """

  def run do
    IO.puts("\n=== Advanced Telemetry Example ===\n")

    # Setup
    setup_telemetry_handlers()
    IO.puts("✓ Telemetry handlers attached\n")

    # Demo 1: Correlation ID tracking
    demo_correlation_tracking()

    # Demo 2: Performance monitoring
    demo_performance_monitoring()

    # Demo 3: Runtime control
    demo_runtime_control()

    # Demo 4: Event aggregation
    demo_event_aggregation()

    IO.puts("\n=== Advanced Telemetry Example Complete ===\n")
  end

  defp setup_telemetry_handlers do
    # Multi-event handler using attach_many
    :telemetry.attach_many(
      "demo-correlation-tracker",
      [
        [:snakepit, :grpc_worker, :execute, :start],
        [:snakepit, :grpc_worker, :execute, :stop]
      ],
      &handle_correlated_events/4,
      %{events: []}
    )

    # Performance monitor
    :telemetry.attach(
      "demo-perf-monitor",
      [:snakepit, :grpc_worker, :execute, :stop],
      &handle_performance_check/4,
      %{threshold_ms: 100}
    )

    # Error tracker
    :telemetry.attach(
      "demo-error-tracker",
      [:snakepit, :grpc_worker, :execute, :stop],
      &handle_python_exception/4,
      nil
    )
  end

  defp handle_correlated_events(event, measurements, metadata, _config) do
    event_name = event |> List.last() |> to_string()
    correlation_id = metadata[:correlation_id] || "none"

    case event_name do
      "start" ->
        IO.puts("  🟡 [Started] correlation_id=#{correlation_id} command=#{metadata.command}")

      "stop" ->
        duration_ms = Map.get(measurements, :duration_ms, 0) * 1.0

        IO.puts(
          "  🟢 [Completed] correlation_id=#{correlation_id} duration=#{Float.round(duration_ms, 2)}ms"
        )

      _ ->
        :ok
    end
  end

  defp handle_performance_check(_event, measurements, metadata, config) do
    duration_ms = Map.get(measurements, :duration_ms, 0) * 1.0
    threshold = config.threshold_ms

    if duration_ms > threshold do
      IO.puts(
        "  ⚠️  [SLOW CALL] command=#{metadata.command} duration=#{Float.round(duration_ms, 2)}ms (threshold: #{threshold}ms)"
      )
    end
  end

  defp handle_python_exception(_event, measurements, metadata, _config) do
    has_error = metadata[:status] == :error or Map.get(measurements, :errors, 0) > 0

    if has_error do
      IO.puts("  ❌ [EXCEPTION] command=#{metadata.command} error=#{inspect(metadata.error)}")
    end
  end

  defp demo_correlation_tracking do
    IO.puts("Demo 1: Correlation ID Tracking")
    IO.puts("  Demonstrates how events are correlated across the Elixir/Python boundary\n")

    # Execute multiple commands to see correlation
    for i <- 1..3 do
      correlation_id = "telemetry-demo-#{i}-#{System.unique_integer([:positive])}"

      case Snakepit.execute("telemetry_demo", %{
             operation: "track_#{i}",
             delay_ms: 20,
             correlation_id: correlation_id
           }) do
        {:ok, _result} ->
          IO.puts("  ✓ Request #{i} completed with correlation_id: #{correlation_id}")

        {:error, reason} ->
          IO.puts("  ❌ Request #{i} failed: #{inspect(reason)}")
      end

      Process.sleep(50)
    end

    IO.puts("")
  end

  defp demo_performance_monitoring do
    IO.puts("Demo 2: Performance Monitoring")
    IO.puts("  Running commands with different delays to trigger performance alerts\n")

    # Fast command (should not trigger alert)
    case Snakepit.execute("telemetry_demo", %{operation: "fast", delay_ms: 10}) do
      {:ok, _} -> IO.puts("  ✓ Fast command completed (no alert expected)")
      {:error, reason} -> IO.puts("  ❌ Error: #{inspect(reason)}")
    end

    Process.sleep(100)

    # Slow command (should trigger alert)
    case Snakepit.execute("telemetry_demo", %{operation: "slow", delay_ms: 150}) do
      {:ok, _} -> IO.puts("  ✓ Slow command completed (alert expected above)")
      {:error, reason} -> IO.puts("  ❌ Error: #{inspect(reason)}")
    end

    Process.sleep(100)
    IO.puts("")
  end

  defp demo_runtime_control do
    IO.puts("Demo 3: Runtime Telemetry Control")
    IO.puts("  Demonstrates adjusting telemetry sampling at runtime\n")

    # Get worker list
    workers = get_worker_ids()

    if Enum.empty?(workers) do
      IO.puts("  ⚠️  No workers available for runtime control demo")
    else
      worker_id = List.first(workers)
      IO.puts("  Target worker: #{worker_id}")

      # Try to adjust sampling (GrpcStream may not be implemented yet)
      try do
        IO.puts("  Attempting to set sampling to 10% for worker #{worker_id}...")
        Snakepit.Telemetry.GrpcStream.update_sampling(worker_id, 0.1)
        IO.puts("  ✓ Sampling rate updated to 10%")
      rescue
        UndefinedFunctionError ->
          IO.puts("  ℹ️  Runtime control requires GrpcStream GenServer (full implementation)")
      end

      Process.sleep(50)

      # Try to toggle telemetry
      try do
        IO.puts("  Attempting to toggle telemetry for worker #{worker_id}...")
        Snakepit.Telemetry.GrpcStream.toggle(worker_id, false)
        IO.puts("  ✓ Telemetry disabled for worker")

        # Execute a command (fewer events expected)
        Snakepit.execute("ping", %{})
        Process.sleep(50)

        # Re-enable
        Snakepit.Telemetry.GrpcStream.toggle(worker_id, true)
        IO.puts("  ✓ Telemetry re-enabled for worker")
      rescue
        UndefinedFunctionError ->
          IO.puts("  ℹ️  Toggling requires GrpcStream GenServer (full implementation)")
      end
    end

    IO.puts("")
  end

  defp demo_event_aggregation do
    IO.puts("Demo 4: Event Aggregation")
    IO.puts("  Collecting metrics across multiple executions\n")

    # Attach a temporary aggregator
    aggregator_pid = spawn_aggregator()

    :telemetry.attach(
      "demo-aggregator",
      [:snakepit, :grpc_worker, :execute, :stop],
      fn _event, measurements, metadata, _config ->
        send(aggregator_pid, {:metric, metadata.command, measurements.duration_ms})
      end,
      nil
    )

    # Run multiple commands
    IO.puts("  Executing 5 commands...")

    for i <- 1..5 do
      Snakepit.execute("add", %{a: i, b: i * 2})
      Process.sleep(20)
    end

    Process.sleep(100)

    # Get aggregated results
    send(aggregator_pid, {:get_stats, self()})

    receive do
      {:stats, stats} ->
        IO.puts("\n  Aggregated Statistics:")

        Enum.each(stats, fn {command, durations} ->
          avg = Enum.sum(durations) / length(durations)
          min = Enum.min(durations)
          max = Enum.max(durations)

          IO.puts("    Command: #{command}")
          IO.puts("      Count: #{length(durations)}")
          IO.puts("      Avg: #{Float.round(avg, 2)}ms")
          IO.puts("      Min: #{Float.round(min * 1.0, 2)}ms")
          IO.puts("      Max: #{Float.round(max * 1.0, 2)}ms")
        end)
    after
      1000 -> IO.puts("  ⚠️  Timeout waiting for aggregated stats")
    end

    :telemetry.detach("demo-aggregator")
    IO.puts("")
  end

  defp spawn_aggregator do
    spawn(fn -> aggregator_loop(%{}) end)
  end

  defp aggregator_loop(stats) do
    receive do
      {:metric, command, duration} ->
        updated_stats =
          Map.update(stats, command, [duration], fn durations ->
            [duration | durations]
          end)

        aggregator_loop(updated_stats)

      {:get_stats, pid} ->
        send(pid, {:stats, stats})
        aggregator_loop(stats)
    end
  end

  defp get_worker_ids do
    # Try to get worker IDs from the pool registry
    try do
      Snakepit.Pool.list_workers()
    rescue
      _ -> []
    end
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  TelemetryAdvancedExample.run()
end)
