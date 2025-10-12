#!/usr/bin/env elixir
#
# TTL-Based Worker Recycling Demo
#
# Demonstrates automatic worker recycling based on Time-To-Live (TTL).
# Workers are automatically replaced after a configured time period to
# prevent memory leaks and ensure fresh Python environments.
#
# This example uses a short 30-second TTL for demonstration purposes.
# In production, use 1-2 hours.
#
# Usage:
#   mix run examples/lifecycle/ttl_recycling_demo.exs
#

# Disable automatic pooling to avoid port conflicts
Application.put_env(:snakepit, :pooling_enabled, false)

defmodule TTLRecyclingDemo do
  require Logger

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Worker Lifecycle Management - TTL Recycling Demo")
    IO.puts(String.duplicate("=", 70) <> "\n")

    # Attach telemetry handler to observe recycling
    attach_telemetry_handler()

    IO.puts("Configuration:")
    IO.puts("  TTL: 30 seconds (short for demo, use 1-2 hours in production)")
    IO.puts("  Check Interval: 60 seconds")
    IO.puts("  Pool: :demo_pool")
    IO.puts("  Workers: 2\n")

    # Note: This demonstrates the configuration pattern
    # Actual TTL recycling requires the full Snakepit application to be running
    IO.puts("To see TTL recycling in action:")

    IO.puts("""

    1. Configure your pool in config/config.exs:

       config :snakepit,
         pooling_enabled: true,
         pools: [
           %{
             name: :demo_pool,
             worker_profile: :process,
             pool_size: 2,
             worker_ttl: {30, :seconds}  # Short for demo
           }
         ]

    2. Start application:
       iex -S mix

    3. Monitor lifecycle manager:
       iex> Snakepit.Worker.LifecycleManager.get_stats()
       # => %{total_workers: 2, ...}

    4. Wait 90 seconds (30s TTL + 60s check interval)

    5. Check stats again:
       iex> Snakepit.Worker.LifecycleManager.get_stats()
       # Workers have been recycled!

    6. View telemetry events in logs:
       Worker pool_worker_1 recycled (reason: ttl_expired)
       Worker pool_worker_2 recycled (reason: ttl_expired)
    """)

    show_production_configuration()
    show_telemetry_monitoring()
    explain_ttl_benefits()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Demo Complete!")
    IO.puts("See lib/snakepit/worker/lifecycle_manager.ex for implementation")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp attach_telemetry_handler do
    :telemetry.attach(
      "ttl-demo-handler",
      [:snakepit, :worker, :recycled],
      fn _event, _measurements, metadata, _config ->
        IO.puts("\n🔄 Telemetry Event Received:")
        IO.puts("  Event: [:snakepit, :worker, :recycled]")
        IO.puts("  Worker: #{metadata.worker_id}")
        IO.puts("  Reason: #{metadata.reason}")
        IO.puts("  Uptime: #{metadata.uptime_seconds}s")
        IO.puts("  Requests: #{metadata.request_count}")
      end,
      nil
    )
  end

  defp show_production_configuration do
    IO.puts("\nProduction Configuration Examples:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    # Hourly recycling (recommended)
    config :snakepit,
      pools: [
        %{
          name: :api_pool,
          worker_profile: :process,
          pool_size: 100,
          worker_ttl: {3600, :seconds}  # 1 hour
        }
      ]

    # Every 2 hours
    worker_ttl: {2, :hours}

    # Daily recycling
    worker_ttl: {1, :days}

    # Disable recycling
    worker_ttl: :infinity

    # Multiple time units
    Time units supported: :seconds, :minutes, :hours, :days
    """)
  end

  defp show_telemetry_monitoring do
    IO.puts("\nMonitoring TTL Recycling:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Attach handler in your application:

    # lib/my_app/application.ex
    def start(_type, _args) do
      :telemetry.attach(
        "worker-ttl-monitor",
        [:snakepit, :worker, :recycled],
        fn _event, _measurements, metadata, _config ->
          if metadata.reason == :ttl_expired do
            Logger.info(\"Worker \#{metadata.worker_id} recycled after \#{metadata.uptime_seconds}s\")

            # Optional: Send to monitoring system
            MyApp.Metrics.increment(\"snakepit.worker.ttl_recycled\")
          end
        end,
        nil
      )

      # ... start children
    end

    Prometheus metrics:
      # Counter
      snakepit_worker_ttl_recycled_total{pool=\"api_pool\"}

      # Histogram of uptimes
      snakepit_worker_uptime_seconds_bucket{pool=\"api_pool\",le=\"3600\"}
    """)
  end

  defp explain_ttl_benefits do
    IO.puts("\nWhy TTL Recycling Matters:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Python processes can accumulate memory over time due to:
      1. Memory fragmentation
      2. Cache growth
      3. Subtle memory leaks in C libraries
      4. NumPy/PyTorch internal caching

    Without TTL recycling (24-hour run):
      Worker memory: 150 MB → 450 MB (+200%)
      Total impact: 15 GB → 45 GB
      Risk: OOM kills, performance degradation

    With 1-hour TTL recycling:
      Worker memory: 150 MB → 180 MB → 150 MB (recycled) → 175 MB
      Total impact: 15 GB → 17.5 GB (stable)
      Benefit: Predictable memory usage, no degradation

    Recommended TTL by workload:
      - API servers: 1-2 hours
      - Background jobs: 4-6 hours
      - Batch processing: 1 hour
      - Long-running analytics: 30 minutes
    """)

    IO.puts("\nAutomatic vs Manual Recycling:")

    IO.puts("""
    Automatic (TTL):
      ✓ Hands-off operation
      ✓ Prevents memory leaks
      ✓ Predictable resource usage
      ✗ May recycle healthy workers

    Manual:
      ✓ Recycle only when needed
      ✓ Based on actual memory usage
      ✗ Requires monitoring and intervention

    Best Practice: Use both!
      - Set conservative TTL (2-4 hours)
      - Monitor memory usage
      - Manually recycle if issues detected
    """)
  end
end

# Run the demo
TTLRecyclingDemo.run()
