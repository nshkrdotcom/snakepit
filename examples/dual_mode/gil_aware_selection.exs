#!/usr/bin/env elixir
#
# GIL-Aware Profile Selection
#
# Demonstrates how to automatically select the appropriate worker profile
# based on Python version and GIL availability.
#
# This example shows:
# 1. Automatic Python version detection
# 2. GIL vs Free-threading differentiation
# 3. Profile recommendation logic
# 4. Library compatibility checking
# 5. Production configuration patterns for both cases
#
# Usage:
#   mix run --no-start examples/dual_mode/gil_aware_selection.exs
#

# Disable automatic pooling
Application.put_env(:snakepit, :pooling_enabled, false)

Code.require_file("../mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule GILAwareSelection do
  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("GIL-Aware Profile Selection")
    IO.puts(String.duplicate("=", 70) <> "\n")

    detect_and_recommend()
    show_gil_vs_free_threading()
    show_library_compatibility_by_gil()
    show_production_patterns()
    show_use_case_matrix()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Demo Complete!")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp detect_and_recommend do
    IO.puts("Python Environment Detection:")
    IO.puts(String.duplicate("-", 70))

    case Snakepit.PythonVersion.detect() do
      {:ok, {major, minor, patch}} ->
        has_free_threading =
          Snakepit.PythonVersion.supports_free_threading?({major, minor, patch})

        recommended = Snakepit.PythonVersion.recommend_profile({major, minor, patch})

        IO.puts("  Detected: Python #{major}.#{minor}.#{patch}")

        IO.puts(
          "  Free-threading: #{if has_free_threading, do: "✅ Available", else: "❌ Not Available (GIL present)"}"
        )

        IO.puts("  Recommended Profile: #{inspect(recommended)}")
        IO.puts("")

        if has_free_threading do
          IO.puts("  🎉 Python 3.13+ Detected!")
          IO.puts("     → GIL can be disabled (--disable-gil or PYTHON_GIL=0)")
          IO.puts("     → Thread profile will provide true multi-core parallelism")
          IO.puts("     → Memory savings: up to 9.4× vs process profile")
          IO.puts("     → CPU throughput: up to 4× improvement")
        else
          IO.puts("  ℹ️  Python #{major}.#{minor} has GIL")
          IO.puts("     → Thread profile still works but limited by GIL")
          IO.puts("     → Process profile recommended for optimal concurrency")
          IO.puts("     → Upgrade to Python 3.13+ for free-threading benefits")
        end

      {:error, :python_not_found} ->
        IO.puts("  ✗ Python not found")
        IO.puts("     → Install Python 3.8+ to use Snakepit")
        IO.puts("     → Python 3.13+ recommended for thread profile")

      {:error, reason} ->
        IO.puts(
          "  ⚠️  Python version check failed: #{Snakepit.Examples.Bootstrap.format_error(reason)}"
        )
    end

    IO.puts("")
  end

  defp show_gil_vs_free_threading do
    IO.puts("GIL vs Free-Threading Comparison:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    WITH GIL (Python ≤3.12):
    ┌─────────────────────────────────────────┐
    │  Python Process (with GIL)              │
    │  ┌──────┐ ┌──────┐ ┌──────┐            │
    │  │Thread│ │Thread│ │Thread│            │
    │  │  1   │ │  2   │ │  3   │            │
    │  └──┬───┘ └──┬───┘ └──┬───┘            │
    │     └────────┼────────┘                 │
    │              │                          │
    │         ┌────▼────┐                     │
    │         │   GIL   │  ← Only 1 thread   │
    │         │ (Lock)  │    runs at a time  │
    │         └─────────┘                     │
    └─────────────────────────────────────────┘
    Result: Threads don't truly run in parallel
    Best approach: Multiple processes (Snakepit process profile)

    WITHOUT GIL (Python 3.13+ free-threading):
    ┌─────────────────────────────────────────┐
    │  Python Process (no GIL)                │
    │  ┌──────┐ ┌──────┐ ┌──────┐            │
    │  │Thread│ │Thread│ │Thread│            │
    │  │  1   │ │  2   │ │  3   │            │
    │  │  ✓   │ │  ✓   │ │  ✓   │            │
    │  └──────┘ └──────┘ └──────┘            │
    │     All run in parallel!                │
    │     (on different CPU cores)            │
    └─────────────────────────────────────────┘
    Result: True multi-core parallelism
    Best approach: Thread pool (Snakepit thread profile)

    Key Difference:
    - GIL: Global lock prevents parallel Python execution
    - Free-threading: No lock, true parallelism possible
    - Snakepit: Provides optimal profile for each case
    """)
  end

  defp show_library_compatibility_by_gil do
    IO.puts("Library Behavior with GIL vs Free-Threading:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    GIL-Releasing Libraries (NumPy, PyTorch, SciPy):
      WITH GIL (Python 3.12):
        - C code releases GIL during computation
        - Multiple threads CAN run C code in parallel
        - But Python code is serialized
        → Thread profile has SOME benefit

      WITHOUT GIL (Python 3.13+):
        - C code runs in parallel (as before)
        - Python code ALSO runs in parallel
        - No serialization bottleneck
        → Thread profile has MASSIVE benefit

    GIL-Holding Libraries (Pandas, pure Python):
      WITH GIL (Python 3.12):
        - Cannot run in parallel at all
        - All threads blocked by GIL
        - Thread profile offers NO benefit
        → Use process profile (isolation)

      WITHOUT GIL (Python 3.13+):
        - Library may not be thread-safe yet
        - Need library updates for safety
        - Thread profile requires caution
        → Check compatibility matrix first

    Snakepit Compatibility Matrix Handles This:
      - Knows which libraries release GIL
      - Warns about thread-unsafe libraries
      - Recommends appropriate profile
      - See: Snakepit.Compatibility.check/2
    """)
  end

  defp show_production_patterns do
    IO.puts("Production Configuration by Python Version:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Scenario 1: Python 3.8-3.12 (GIL present)
    ─────────────────────────────────────────
    Recommendation: Process Profile

    config :snakepit,
      pools: [
        %{
          name: :default,
          worker_profile: :process,      # ← PROCESS for GIL compatibility
          pool_size: 100,
          adapter_env: [
            {"OPENBLAS_NUM_THREADS", "1"},  # Force single-threading
            {"OMP_NUM_THREADS", "1"}
          ],
          worker_ttl: {7200, :seconds}
        }
      ]

    Why:
      - GIL prevents thread-level parallelism anyway
      - Process isolation is safer
      - High concurrency via many processes
      - Proven stable pattern

    Scenario 2: Python 3.13+ (Free-threading available)
    ───────────────────────────────────────────────────
    Recommendation: Hybrid (Both Profiles)

    config :snakepit,
      pools: [
        # I/O-bound: Process profile (still optimal)
        %{
          name: :api_pool,
          worker_profile: :process,
          pool_size: 100
        },

        # CPU-bound: Thread profile (leverage free-threading!)
        %{
          name: :compute_pool,
          worker_profile: :thread,       # ← THREAD for CPU parallelism
          pool_size: 4,
          threads_per_worker: 16,
          adapter_args: ["--max-workers", "16"],
          adapter_env: [
            {"OPENBLAS_NUM_THREADS", "16"},  # Allow multi-threading!
            {"OMP_NUM_THREADS", "16"}
          ],
          worker_ttl: {3600, :seconds}
        }
      ]

    Why:
      - Free-threading enables true thread parallelism
      - CPU-bound work benefits massively (4× improvement)
      - Memory savings significant (9.4× reduction)
      - I/O work still better with process profile
      - Hybrid approach gets best of both worlds
    """)
  end

  defp show_use_case_matrix do
    IO.puts("Use Case Decision Matrix:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    ┌────────────────┬─────────────┬────────────┬──────────────────┐
    │ Python Version │ Workload    │ Profile    │ Reason           │
    ├────────────────┼─────────────┼────────────┼──────────────────┤
    │ 3.8-3.12       │ I/O-bound   │ :process   │ GIL + concurrency│
    │ 3.8-3.12       │ CPU-bound   │ :process   │ GIL limits threads│
    │ 3.13+ (GIL)    │ I/O-bound   │ :process   │ Proven pattern   │
    │ 3.13+ (GIL)    │ CPU-bound   │ :process   │ GIL still present│
    │ 3.13+ (no GIL) │ I/O-bound   │ :process   │ Stability        │
    │ 3.13+ (no GIL) │ CPU-bound   │ :thread    │ 4× performance! │
    └────────────────┴─────────────┴────────────┴──────────────────┘

    Decision Algorithm:
      1. Detect Python version
      2. Check if free-threading available (3.13+)
      3. Check if GIL disabled (PYTHON_GIL=0)
      4. Analyze workload type (I/O vs CPU)
      5. Check library compatibility
      6. Select profile based on all factors

    Snakepit Automation:
      # Automatic recommendation
      recommended = Snakepit.PythonVersion.recommend_profile()

      # Library compatibility check
      {:ok, report} = Snakepit.Compatibility.generate_report(
        ["numpy", "pandas", "torch"],
        :thread
      )

      # Make informed decision
      profile = if has_cpu_workload and recommended == :thread do
        :thread
      else
        :process
      end
    """)
  end
end

# Run the demo with clean startup/shutdown
Snakepit.Examples.Bootstrap.run_example(
  fn ->
    GILAwareSelection.run()
  end,
  await_pool: false
)
