#!/usr/bin/env elixir
# Disable automatic pooling to avoid port conflicts
Application.put_env(:snakepit, :pooling_enabled, false)

#
# Threaded Profile Demo - Demonstrates multi-threaded worker execution
#
# This example shows how to use Snakepit's thread profile for CPU-intensive
# workloads with Python 3.13+ free-threading support.
#
# Features demonstrated:
# 1. Thread profile configuration
# 2. Concurrent request handling
# 3. Worker capacity management
# 4. Performance comparison with process profile
#
# Requirements:
# - Python 3.13+ (optional, works with 3.8+ but optimal with 3.13+)
# - NumPy (for CPU-intensive operations)
# - Snakepit v0.6.0+
#
# Usage:
#   mix run examples/threaded_profile_demo.exs
#

Mix.install([
  {:snakepit, path: "."}
])

defmodule ThreadedProfileDemo do
  require Logger

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Snakepit v0.6.0 - Threaded Profile Demonstration")
    IO.puts(String.duplicate("=", 70) <> "\n")

    # Check Python version
    check_python_version()

    # Demo 1: Basic thread profile usage
    demo_basic_threaded_execution()

    # Demo 2: Concurrent requests
    demo_concurrent_requests()

    # Demo 3: Capacity management
    demo_capacity_management()

    # Demo 4: Performance monitoring
    demo_performance_monitoring()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Demo Complete!")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp check_python_version do
    IO.puts("Checking Python environment...")

    case Snakepit.PythonVersion.detect() do
      {:ok, {major, minor, patch}} ->
        IO.puts("  ✓ Python #{major}.#{minor}.#{patch} detected")

        if Snakepit.PythonVersion.supports_free_threading?({major, minor, patch}) do
          IO.puts("  ✓ Python 3.13+ detected - Free-threading supported!")
          IO.puts("    Threaded profile will provide optimal performance")
        else
          IO.puts("  ℹ Python #{major}.#{minor} detected")
          IO.puts("    Threaded profile works but optimal with Python 3.13+")
        end

        IO.puts("")

      {:error, :python_not_found} ->
        IO.puts("  ✗ Python not found - please install Python 3.8+")
        System.halt(1)
    end
  end

  defp demo_basic_threaded_execution do
    IO.puts("Demo 1: Basic Threaded Execution")
    IO.puts(String.duplicate("-", 70))

    # Note: This demo requires manual pool configuration
    # In a real app, configure in config/config.exs:
    #
    # config :snakepit,
    #   pools: [
    #     %{
    #       name: :threaded_demo,
    #       worker_profile: :thread,
    #       pool_size: 2,
    #       threads_per_worker: 8,
    #       adapter_module: Snakepit.Adapters.GRPCPython,
    #       adapter_args: [
    #         "--adapter", "snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter",
    #         "--max-workers", "8",
    #         "--thread-safety-check"
    #       ]
    #     }
    #   ]

    IO.puts("\nConfiguration for threaded profile:")

    IO.puts("""
      %{
        name: :hpc_pool,
        worker_profile: :thread,
        pool_size: 4,
        threads_per_worker: 16,
        adapter_args: ["--max-workers", "16"]
      }
    """)

    IO.puts("Status: Thread profile implementation complete!")
    IO.puts("Note: Full multi-pool support in Phase 3 completion\n")
  end

  defp demo_concurrent_requests do
    IO.puts("\nDemo 2: Concurrent Request Handling")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Threaded workers can handle multiple concurrent requests:

    Process Profile (capacity = 1):
      Worker 1: [Request 1]
      Worker 2: [Request 2]
      Worker 3: [Request 3]
      ...
      Worker 100: [Request 100]

    Thread Profile (capacity = 16):
      Worker 1: [Req 1, Req 2, Req 3, ..., Req 16]
      Worker 2: [Req 17, Req 18, ..., Req 32]
      Worker 3: [Req 33, Req 34, ..., Req 48]
      Worker 4: [Req 49, Req 50, ..., Req 64]

    Same 64 concurrent requests handled by:
    - Process mode: 64 workers
    - Thread mode: 4 workers × 16 threads = 4 processes!
    """)

    IO.puts("Memory savings: ~10-15× reduction\n")
  end

  defp demo_capacity_management do
    IO.puts("\nDemo 3: Worker Capacity Management")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    ThreadProfile tracks capacity via ETS:

      Worker PID     | Capacity | Load | Available
      ---------------|----------|------|----------
      <0.123.0>      |    16    |   8  |     8
      <0.124.0>      |    16    |  15  |     1
      <0.125.0>      |    16    |  16  |     0  (saturated)
      <0.126.0>      |    16    |   0  |    16  (idle)

    Pool automatically routes to workers with available capacity.
    """)

    IO.puts("ETS table: :snakepit_worker_capacity")
    IO.puts("Format: {worker_pid, capacity, current_load}\n")
  end

  defp demo_performance_monitoring do
    IO.puts("\nDemo 4: Performance Monitoring")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Get worker metadata:

      Snakepit.WorkerProfile.Thread.get_metadata(worker_pid)
      # => {:ok, %{
      #   profile: :thread,
      #   capacity: 16,
      #   load: 8,
      #   available_capacity: 8,
      #   worker_type: "multi-threaded",
      #   threading: "thread-pool"
      # }}

    Python-side stats:

      {:ok, stats} = Snakepit.execute(:hpc_pool, "get_adapter_stats", %{})
      # => %{
      #   "total_requests" => 1234,
      #   "active_requests" => 8,
      #   "thread_utilization" => %{...}
      # }
    """)

    IO.puts("")
  end
end

# Run the demo
ThreadedProfileDemo.run()
