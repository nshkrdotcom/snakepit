#!/usr/bin/env elixir

# Basic Telemetry Example
# Demonstrates how to attach telemetry handlers and receive events from Python workers
# Usage: mix run --no-start examples/telemetry_basic.exs

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
    pool_size: 2,
    adapter_module: Snakepit.Adapters.GRPCPython
  }
])

Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
Application.put_env(:snakepit, :grpc_port, 50051)
Snakepit.Examples.Bootstrap.ensure_grpc_port!()

# Suppress Snakepit internal logs for clean output
Application.put_env(:snakepit, :log_level, :warning)

defmodule TelemetryBasicExample do
  @moduledoc """
  Demonstrates basic telemetry usage:
  1. Attaching handlers to Snakepit telemetry events
  2. Receiving events from Python workers
  3. Observing the bidirectional telemetry stream
  """

  def run do
    IO.puts("\n=== Basic Telemetry Example ===\n")
    IO.puts("This example demonstrates Snakepit's distributed telemetry system.\n")

    # Attach telemetry handlers
    setup_telemetry_handlers()

    IO.puts("✓ Telemetry handlers attached\n")
    IO.puts("Starting telemetry demonstrations...\n")

    # Demo 1: Worker lifecycle events
    demo_worker_lifecycle()

    # Demo 2: Python tool execution events
    demo_python_execution()

    # Demo 3: Python telemetry API (emit and span)
    demo_python_telemetry_api()

    IO.puts("\n=== Telemetry Example Complete ===\n")
    IO.puts("Summary:")
    IO.puts("  - Worker lifecycle events: spawned, terminated")
    IO.puts("  - Python execution events: call start/stop")
    IO.puts("  - Python telemetry API: custom events and spans")
    IO.puts("  - All events flow through Elixir's :telemetry system\n")
  end

  defp setup_telemetry_handlers do
    # Handler 1: Worker lifecycle events
    :telemetry.attach(
      "demo-worker-lifecycle",
      [:snakepit, :pool, :worker, :spawned],
      &handle_worker_spawned/4,
      nil
    )

    # Handler 2: Python call events
    :telemetry.attach(
      "demo-python-call-stop",
      [:snakepit, :grpc_worker, :execute, :stop],
      &handle_python_call_stop/4,
      nil
    )

    # Handler 3: Python tool execution events (from Python telemetry API)
    :telemetry.attach(
      "demo-python-tool-start",
      [:snakepit, :python, :tool, :execution, :start],
      &handle_python_tool_start/4,
      nil
    )

    :telemetry.attach(
      "demo-python-tool-stop",
      [:snakepit, :python, :tool, :execution, :stop],
      &handle_python_tool_stop/4,
      nil
    )

    # Handler 4: Custom Python metrics
    :telemetry.attach(
      "demo-python-result-size",
      [:snakepit, :python, :tool, :result_size],
      &handle_python_result_size/4,
      nil
    )
  end

  # Event handlers
  defp handle_worker_spawned(_event, measurements, metadata, _config) do
    duration_native = Map.get(measurements, :duration, 0)
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond) * 1.0

    IO.puts(
      "  📊 [Worker Spawned] worker_id=#{metadata.worker_id} duration=#{Float.round(duration_ms, 2)}ms"
    )
  end

  defp handle_python_call_stop(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0) * 1.0

    IO.puts(
      "  📊 [Worker Call] command=#{metadata.command} duration=#{Float.round(duration_ms, 2)}ms"
    )
  end

  defp handle_python_tool_start(_event, _measurements, metadata, _config) do
    tool = metadata["tool"] || "unknown"
    operation = metadata["operation"] || ""
    IO.puts("  🔷 [Python Tool Start] tool=#{tool} operation=#{operation}")
  end

  defp handle_python_tool_stop(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration / 1_000_000
    tool = metadata["tool"] || "unknown"
    operation = metadata["operation"] || ""

    IO.puts(
      "  🔶 [Python Tool Stop] tool=#{tool} operation=#{operation} duration=#{Float.round(duration_ms, 2)}ms"
    )
  end

  defp handle_python_result_size(_event, measurements, metadata, _config) do
    bytes = measurements.bytes
    tool = metadata["tool"] || "unknown"
    IO.puts("  📏 [Result Size] tool=#{tool} bytes=#{bytes}")
  end

  # Demos
  defp demo_worker_lifecycle do
    IO.puts("Demo 1: Worker Lifecycle Events")
    IO.puts("  (Events will be emitted as workers are already running)")
    IO.puts("")
  end

  defp demo_python_execution do
    IO.puts("Demo 2: Python Execution Events")
    IO.puts("  Executing simple commands to trigger call events...\n")

    # Execute a few commands
    case Snakepit.execute("ping", %{}) do
      {:ok, _result} -> :ok
      {:error, reason} -> IO.puts("  ❌ Error: #{inspect(reason)}")
    end

    case Snakepit.execute("add", %{a: 10, b: 32}) do
      {:ok, result} -> IO.puts("  ✓ Result: #{inspect(result)}")
      {:error, reason} -> IO.puts("  ❌ Error: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp demo_python_telemetry_api do
    IO.puts("Demo 3: Python Telemetry API (emit and span)")
    IO.puts("  Using the telemetry_demo tool to emit custom events from Python...\n")

    # The telemetry_demo tool uses the Python telemetry API:
    # - telemetry.emit() for custom events
    # - telemetry.span() for automatic timing
    case Snakepit.execute("telemetry_demo", %{operation: "compute", delay_ms: 50}) do
      {:ok, result} ->
        IO.puts("  ✓ Telemetry demo completed:")
        IO.puts("    - Telemetry enabled: #{result["telemetry_enabled"]}")
        IO.puts("    - Correlation ID: #{result["correlation_id"]}")
        IO.puts("    - Message: #{result["message"]}")

      {:error, reason} ->
        IO.puts("  ❌ Error: #{inspect(reason)}")
    end

    IO.puts("")
  end
end

# Run the example with proper cleanup
Snakepit.Examples.Bootstrap.run_example(fn ->
  TelemetryBasicExample.run()
end)
