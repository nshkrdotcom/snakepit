#!/usr/bin/env elixir

# Telemetry Monitoring Example
# Demonstrates practical monitoring patterns including:
# - Worker health monitoring
# - Performance tracking and alerting
# - Error rate monitoring
# - Resource usage tracking
# Usage: elixir examples/telemetry_monitoring.exs

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
  {:protobuf, "~> 0.14.1"}
])

defmodule TelemetryMonitoringExample do
  @moduledoc """
  Demonstrates production-ready monitoring patterns using Snakepit telemetry:
  1. Worker health monitoring with restart detection
  2. Performance SLA tracking
  3. Error rate monitoring
  4. Queue depth alerting
  5. Metrics dashboard simulation
  """

  def run do
    IO.puts("\n=== Telemetry Monitoring Example ===\n")
    IO.puts("Simulating production monitoring patterns...\n")

    # Initialize monitoring
    monitor = start_monitoring()

    # Setup telemetry handlers
    setup_monitoring_handlers(monitor)
    IO.puts("✓ Monitoring system initialized\n")

    # Run workload simulations
    simulate_normal_workload()
    simulate_slow_operations()
    simulate_concurrent_load()

    # Display monitoring dashboard
    display_dashboard(monitor)

    IO.puts("\n=== Monitoring Example Complete ===\n")
  end

  defp start_monitoring do
    spawn(fn -> monitoring_loop(init_metrics()) end)
  end

  defp init_metrics do
    %{
      call_count: 0,
      error_count: 0,
      slow_call_count: 0,
      total_duration: 0,
      worker_restarts: %{},
      queue_depth_max: 0,
      events_by_type: %{}
    }
  end

  defp setup_monitoring_handlers(monitor) do
    # 1. Worker health monitoring
    :telemetry.attach(
      "monitor-worker-health",
      [:snakepit, :pool, :worker, :restarted],
      fn _event, measurements, metadata, _ ->
        worker_id = metadata.worker_id
        restart_count = measurements[:restart_count] || 1

        IO.puts("  ⚠️  [WORKER RESTART] worker=#{worker_id} count=#{restart_count}")
        send(monitor, {:worker_restart, worker_id, restart_count})

        if restart_count > 3 do
          IO.puts("  🚨 [ALERT] Worker #{worker_id} restarting frequently! (#{restart_count} restarts)")
        end
      end,
      nil
    )

    # 2. Performance tracking
    :telemetry.attach(
      "monitor-performance",
      [:snakepit, :python, :call, :stop],
      fn _event, measurements, metadata, _ ->
        duration_ms = measurements.duration / 1_000_000
        command = metadata.command

        send(monitor, {:call_completed, command, duration_ms})

        # SLA alerting (>200ms is slow)
        if duration_ms > 200 do
          IO.puts("  🐢 [SLOW CALL] command=#{command} duration=#{Float.round(duration_ms, 2)}ms")
        end
      end,
      nil
    )

    # 3. Error monitoring
    :telemetry.attach(
      "monitor-errors",
      [:snakepit, :python, :call, :exception],
      fn _event, _measurements, metadata, _ ->
        command = metadata.command
        error = metadata[:error] || "unknown"

        IO.puts("  ❌ [ERROR] command=#{command} error=#{inspect(error)}")
        send(monitor, {:error, command, error})
      end,
      nil
    )

    # 4. Queue depth monitoring
    :telemetry.attach(
      "monitor-queue-depth",
      [:snakepit, :pool, :queue, :enqueued],
      fn _event, _measurements, metadata, _ ->
        queue_depth = metadata[:queue_depth] || 0
        send(monitor, {:queue_depth, queue_depth})

        if queue_depth > 10 do
          IO.puts("  📊 [HIGH QUEUE] depth=#{queue_depth} - Consider scaling up workers")
        end
      end,
      nil
    )

    # 5. General event counter
    :telemetry.attach_many(
      "monitor-event-counter",
      [
        [:snakepit, :pool, :worker, :spawned],
        [:snakepit, :pool, :worker, :terminated],
        [:snakepit, :python, :tool, :execution, :stop]
      ],
      fn event, _measurements, _metadata, _ ->
        event_name = Enum.join(event, ".")
        send(monitor, {:event, event_name})
      end,
      nil
    )
  end

  defp monitoring_loop(metrics) do
    receive do
      {:call_completed, command, duration_ms} ->
        updated = %{
          metrics
          | call_count: metrics.call_count + 1,
            total_duration: metrics.total_duration + duration_ms,
            slow_call_count:
              if duration_ms > 200,
                do: metrics.slow_call_count + 1,
                else: metrics.slow_call_count
        }

        monitoring_loop(updated)

      {:error, _command, _error} ->
        monitoring_loop(%{metrics | error_count: metrics.error_count + 1})

      {:worker_restart, worker_id, count} ->
        restarts = Map.put(metrics.worker_restarts, worker_id, count)
        monitoring_loop(%{metrics | worker_restarts: restarts})

      {:queue_depth, depth} ->
        max_depth = max(metrics.queue_depth_max, depth)
        monitoring_loop(%{metrics | queue_depth_max: max_depth})

      {:event, event_name} ->
        events = Map.update(metrics.events_by_type, event_name, 1, &(&1 + 1))
        monitoring_loop(%{metrics | events_by_type: events})

      {:get_metrics, pid} ->
        send(pid, {:metrics, metrics})
        monitoring_loop(metrics)

      _ ->
        monitoring_loop(metrics)
    end
  end

  defp simulate_normal_workload do
    IO.puts("Scenario 1: Normal Workload")
    IO.puts("  Running 5 standard operations...\n")

    for i <- 1..5 do
      case Snakepit.execute("add", %{a: i, b: i * 2}) do
        {:ok, result} -> IO.puts("  ✓ Operation #{i} completed: #{inspect(result)}")
        {:error, reason} -> IO.puts("  ❌ Operation #{i} failed: #{inspect(reason)}")
      end

      Process.sleep(50)
    end

    IO.puts("")
  end

  defp simulate_slow_operations do
    IO.puts("Scenario 2: Slow Operations (SLA violations)")
    IO.puts("  Running operations with delays...\n")

    delays = [50, 150, 250]

    for delay <- delays do
      case Snakepit.execute("telemetry_demo", %{operation: "slow_op", delay_ms: delay}) do
        {:ok, _result} -> IO.puts("  ✓ Operation with #{delay}ms delay completed")
        {:error, reason} -> IO.puts("  ❌ Operation failed: #{inspect(reason)}")
      end

      Process.sleep(100)
    end

    IO.puts("")
  end

  defp simulate_concurrent_load do
    IO.puts("Scenario 3: Concurrent Load (Queue Pressure)")
    IO.puts("  Launching 10 concurrent requests...\n")

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          case Snakepit.execute("telemetry_demo", %{operation: "concurrent_#{i}", delay_ms: 100}) do
            {:ok, _} -> :ok
            {:error, _} -> :error
          end
        end)
      end

    results = Task.await_many(tasks, 30_000)
    success_count = Enum.count(results, &(&1 == :ok))

    IO.puts("  ✓ Completed: #{success_count}/10 requests\n")
    Process.sleep(200)
  end

  defp display_dashboard(monitor) do
    send(monitor, {:get_metrics, self()})

    receive do
      {:metrics, metrics} ->
        IO.puts("╔════════════════════════════════════════════════╗")
        IO.puts("║         MONITORING DASHBOARD                   ║")
        IO.puts("╠════════════════════════════════════════════════╣")

        # Performance metrics
        avg_duration =
          if metrics.call_count > 0,
            do: Float.round(metrics.total_duration / metrics.call_count, 2),
            else: 0

        sla_compliance =
          if metrics.call_count > 0,
            do: Float.round((metrics.call_count - metrics.slow_call_count) / metrics.call_count * 100, 1),
            else: 100.0

        IO.puts("║ Performance Metrics:                           ║")
        IO.puts("║   Total Calls: #{pad_right(metrics.call_count, 32)} ║")
        IO.puts("║   Avg Duration: #{pad_right("#{avg_duration}ms", 30)} ║")
        IO.puts("║   Slow Calls: #{pad_right(metrics.slow_call_count, 32)} ║")
        IO.puts("║   SLA Compliance: #{pad_right("#{sla_compliance}%", 28)} ║")
        IO.puts("╠════════════════════════════════════════════════╣")

        # Error metrics
        error_rate =
          if metrics.call_count > 0,
            do: Float.round(metrics.error_count / metrics.call_count * 100, 1),
            else: 0.0

        IO.puts("║ Reliability Metrics:                           ║")
        IO.puts("║   Error Count: #{pad_right(metrics.error_count, 31)} ║")
        IO.puts("║   Error Rate: #{pad_right("#{error_rate}%", 32)} ║")
        IO.puts("║   Max Queue Depth: #{pad_right(metrics.queue_depth_max, 27)} ║")
        IO.puts("╠════════════════════════════════════════════════╣")

        # Worker health
        IO.puts("║ Worker Health:                                 ║")

        if map_size(metrics.worker_restarts) > 0 do
          Enum.each(metrics.worker_restarts, fn {worker_id, count} ->
            IO.puts("║   #{pad_right("#{worker_id}: #{count} restarts", 45)} ║")
          end)
        else
          IO.puts("║   All workers healthy ✓                        ║")
        end

        IO.puts("╠════════════════════════════════════════════════╣")

        # Event counts
        IO.puts("║ Event Breakdown:                               ║")

        if map_size(metrics.events_by_type) > 0 do
          metrics.events_by_type
          |> Enum.take(5)
          |> Enum.each(fn {event, count} ->
            short_event = String.slice(event, 0, 30)
            IO.puts("║   #{pad_right("#{short_event}: #{count}", 45)} ║")
          end)
        else
          IO.puts("║   No additional events tracked                 ║")
        end

        IO.puts("╚════════════════════════════════════════════════╝")
    after
      1000 -> IO.puts("⚠️  Timeout retrieving metrics")
    end
  end

  defp pad_right(value, width) do
    str = to_string(value)
    padding = max(0, width - String.length(str))
    str <> String.duplicate(" ", padding)
  end
end

# Run the example with proper cleanup
Snakepit.run_as_script(fn ->
  TelemetryMonitoringExample.run()
end)
