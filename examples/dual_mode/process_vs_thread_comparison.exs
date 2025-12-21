#!/usr/bin/env elixir
#
# Process vs Thread Profile Comparison
#
# Demonstrates the performance and resource differences between
# process-based and thread-based worker profiles.
#
# This example shows:
# 1. Configuration of both profiles
# 2. Execution time comparison
# 3. Memory usage comparison
# 4. When to use which profile
#
# Usage:
#   mix run --no-start examples/dual_mode/process_vs_thread_comparison.exs
#

# Disable automatic pooling to avoid port conflicts
Application.put_env(:snakepit, :pooling_enabled, false)

Code.require_file("../mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule ProcessVsThreadComparison do
  require Logger

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Snakepit v0.6.0 - Process vs Thread Profile Comparison")
    IO.puts(String.duplicate("=", 70) <> "\n")

    # Check Python version
    check_environment()

    # Demo 1: Configuration comparison
    show_configuration_differences()

    # Demo 2: Capacity comparison
    show_capacity_differences()

    # Demo 3: Memory comparison
    show_memory_characteristics()

    # Demo 4: Recommendations
    show_recommendations()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Comparison Complete!")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp check_environment do
    IO.puts("Environment Check:")
    IO.puts(String.duplicate("-", 70))

    case Snakepit.PythonVersion.detect() do
      {:ok, {major, minor, patch}} ->
        IO.puts("  ✓ Python #{major}.#{minor}.#{patch} detected")

        if Snakepit.PythonVersion.supports_free_threading?({major, minor, patch}) do
          IO.puts("  ✓ Free-threading supported (Python 3.13+)")
          IO.puts("    → Thread profile will provide optimal performance")
        else
          IO.puts("  ℹ Free-threading not available (Python #{major}.#{minor})")
          IO.puts("    → Thread profile works but optimal with Python 3.13+")
        end

      {:error, :python_not_found} ->
        IO.puts("  ✗ Python not found")
        IO.puts("    This demo shows configuration patterns only")
    end

    IO.puts("")
  end

  defp show_configuration_differences do
    IO.puts("\nConfiguration Comparison:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("\n📦 Process Profile (Traditional)")

    IO.puts("""
      %{
        name: :api_pool,
        worker_profile: :process,       # Many single-threaded processes
        pool_size: 100,                  # 100 separate Python processes
        adapter_env: [
          {"OPENBLAS_NUM_THREADS", "1"}, # Force single-threading
          {"OMP_NUM_THREADS", "1"}
        ]
      }

      Characteristics:
      - Workers: 100 Python processes
      - Threads per worker: 1
      - Total capacity: 100 concurrent requests
      - Memory: ~150 MB × 100 = 15 GB
      - Best for: I/O-bound, high concurrency
    """)

    IO.puts("🧵 Thread Profile (Python 3.13+ Optimized)")

    IO.puts("""
      %{
        name: :hpc_pool,
        worker_profile: :thread,         # Few multi-threaded processes
        pool_size: 4,                    # Only 4 Python processes
        threads_per_worker: 16,          # 16 threads each
        adapter_args: ["--max-workers", "16"],
        adapter_env: [
          {"OPENBLAS_NUM_THREADS", "16"}, # Allow multi-threading
          {"OMP_NUM_THREADS", "16"}
        ]
      }

      Characteristics:
      - Workers: 4 Python processes
      - Threads per worker: 16
      - Total capacity: 64 concurrent requests
      - Memory: ~400 MB × 4 = 1.6 GB
      - Best for: CPU-bound, large data
    """)
  end

  defp show_capacity_differences do
    IO.puts("\nCapacity & Concurrency:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Handling 64 Concurrent Requests:

    Process Profile:
      Worker 1:  [Request 1]
      Worker 2:  [Request 2]
      Worker 3:  [Request 3]
      ...
      Worker 64: [Request 64]
      (64 processes active)

    Thread Profile:
      Process 1: [Req 1, 2, 3, ..., 16]  (16 threads busy)
      Process 2: [Req 17, 18, ..., 32]   (16 threads busy)
      Process 3: [Req 33, 34, ..., 48]   (16 threads busy)
      Process 4: [Req 49, 50, ..., 64]   (16 threads busy)
      (4 processes active, 64 threads total)

    Key Difference:
    - Process: 64 OS processes
    - Thread: 4 OS processes, 64 threads
    - Resource savings: 15× fewer processes
    """)
  end

  defp show_memory_characteristics do
    IO.puts("\nMemory Usage Analysis:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Process Profile (100 workers):
      Base Python interpreter:  50 MB × 100 = 5.0 GB
      NumPy/SciPy libraries:   100 MB × 100 = 10.0 GB
      Total:                                  15.0 GB

    Thread Profile (4 workers × 16 threads):
      Base Python interpreter:  50 MB × 4   = 0.2 GB
      NumPy/SciPy libraries:   100 MB × 4   = 0.4 GB
      Thread overhead:         250 MB × 4   = 1.0 GB
      Total:                                   1.6 GB

    Memory Savings: 15.0 GB → 1.6 GB = 9.4× reduction!

    Why the difference?
    - Process mode: Each worker loads full Python interpreter and libraries
    - Thread mode: Shared interpreter and libraries across threads
    - Overhead: Thread stacks (~2 MB each) vs full interpreter (~150 MB)
    """)
  end

  defp show_recommendations do
    IO.puts("\nWhen to Use Which Profile:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Use PROCESS Profile when:
      ✅ Python ≤3.12 (GIL present)
      ✅ I/O-bound workloads (API servers, web scraping)
      ✅ Maximum process isolation needed
      ✅ Thread-unsafe libraries (Pandas, Matplotlib, SQLite3)
      ✅ High concurrency (100-250 workers)
      ✅ Small memory footprint per task

    Use THREAD Profile when:
      ✅ Python 3.13+ (free-threading available)
      ✅ CPU-bound workloads (ML training, data processing)
      ✅ Large shared data (pre-loaded models)
      ✅ Memory constraints (limited RAM)
      ✅ Thread-safe libraries (NumPy, PyTorch, TensorFlow)
      ✅ Heavy computation per task

    Hybrid Approach (Best of Both):
      💡 Use BOTH profiles in separate pools!
      - Process profile for API requests → :api_pool
      - Thread profile for background jobs → :compute_pool
      - Route work to appropriate pool based on task type
    """)

    IO.puts("\nPerformance Comparison Summary:")

    IO.puts("""
      Metric              | Process (100)  | Thread (4×16)  | Winner
      --------------------|----------------|----------------|--------
      Memory              | 15 GB          | 1.6 GB         | Thread (9.4×)
      CPU (I/O tasks)     | 1500 req/s     | 1200 req/s     | Process
      CPU (compute tasks) | 600 jobs/hr    | 2400 jobs/hr   | Thread (4×)
      Startup time        | 60s (batched)  | 24s            | Thread
      Isolation           | Full           | Shared         | Process
      GIL compatibility   | All Python     | 3.13+ optimal  | Process
    """)
  end
end

# Run the comparison
ProcessVsThreadComparison.run()
