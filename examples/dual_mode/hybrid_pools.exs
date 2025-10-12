#!/usr/bin/env elixir
#
# Hybrid Pools Demo - Multiple Pools with Different Profiles
#
# Demonstrates running multiple worker pools with different profiles
# simultaneously. This is the recommended production pattern for
# mixed workloads.
#
# Configuration:
# - Process pool for API requests (high concurrency, I/O-bound)
# - Thread pool for background computation (CPU-bound)
#
# Usage:
#   mix run examples/dual_mode/hybrid_pools.exs
#

# Disable automatic pooling to avoid port conflicts
Application.put_env(:snakepit, :pooling_enabled, false)

defmodule HybridPoolsDemo do
  require Logger

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Hybrid Pools - Best of Both Worlds")
    IO.puts(String.duplicate("=", 70) <> "\n")

    show_architecture()
    show_configuration()
    show_usage_patterns()
    show_routing_logic()
    show_resource_utilization()
    show_real_world_example()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Hybrid Pools Demo Complete!")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp show_architecture do
    IO.puts("Architecture Overview:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    ┌──────────────────────────────────────────────────────────────┐
    │                    Application Layer                         │
    │  Routes requests to appropriate pool based on workload type  │
    └──────────────────────────────────────────────────────────────┘
                              ▼           ▼
           ┌──────────────────────┐   ┌──────────────────────┐
           │   API Pool           │   │   Compute Pool       │
           │   (Process Profile)  │   │   (Thread Profile)   │
           ├──────────────────────┤   ├──────────────────────┤
           │ Workers: 100         │   │ Workers: 4           │
           │ Threads: 1 each      │   │ Threads: 16 each     │
           │ Capacity: 100        │   │ Capacity: 64         │
           │ Memory: 15 GB        │   │ Memory: 1.6 GB       │
           └──────────────────────┘   └──────────────────────┘
                    ▼                            ▼
           I/O-bound requests         CPU-bound computation
           (Fast, many)               (Slow, intensive)
    """)
  end

  defp show_configuration do
    IO.puts("\nConfiguration:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    # config/config.exs
    config :snakepit,
      pooling_enabled: true,
      pools: [
        # Pool 1: API requests (process profile)
        %{
          name: :api_pool,
          worker_profile: :process,
          pool_size: 100,
          adapter_module: Snakepit.Adapters.GRPCPython,
          adapter_args: [
            "--adapter",
            "snakepit_bridge.adapters.showcase.ShowcaseAdapter"
          ],
          adapter_env: [
            {"OPENBLAS_NUM_THREADS", "1"},
            {"OMP_NUM_THREADS", "1"}
          ],
          # Recycle every 2 hours or 10,000 requests
          worker_ttl: {7200, :seconds},
          worker_max_requests: 10_000
        },

        # Pool 2: Background computation (thread profile)
        %{
          name: :compute_pool,
          worker_profile: :thread,
          pool_size: 4,
          threads_per_worker: 16,
          adapter_module: Snakepit.Adapters.GRPCPython,
          adapter_args: [
            "--adapter",
            "snakepit_bridge.adapters.threaded_showcase.ThreadedShowcaseAdapter",
            "--max-workers",
            "16",
            "--thread-safety-check"
          ],
          adapter_env: [
            {"OPENBLAS_NUM_THREADS", "16"},
            {"OMP_NUM_THREADS", "16"}
          ],
          # Recycle every hour or 1,000 requests
          worker_ttl: {3600, :seconds},
          worker_max_requests: 1000
        }
      ]
    """)
  end

  defp show_usage_patterns do
    IO.puts("\nUsage Patterns:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Route requests to appropriate pool:

    defmodule MyApp.TaskRouter do
      def execute_task(task) do
        case classify_task(task) do
          :io_bound ->
            # Use process pool for I/O tasks
            Snakepit.execute(:api_pool, task.command, task.args)

          :cpu_bound ->
            # Use thread pool for CPU tasks
            Snakepit.execute(:compute_pool, task.command, task.args)
        end
      end

      defp classify_task(task) do
        case task.type do
          # I/O-bound: API calls, database queries, file I/O
          type when type in [:api_call, :db_query, :file_read] ->
            :io_bound

          # CPU-bound: ML inference, data processing, computation
          type when type in [:ml_inference, :data_transform, :compute] ->
            :cpu_bound

          # Default to process pool for safety
          _ ->
            :io_bound
        end
      end
    end

    # Examples:

    # Fast API request → Process pool
    {:ok, result} = Snakepit.execute(:api_pool, "fetch_user", %{id: 123})

    # Heavy computation → Thread pool
    {:ok, result} = Snakepit.execute(:compute_pool, "train_model", %{
      dataset: large_data,
      epochs: 100
    })
    """)
  end

  defp show_routing_logic do
    IO.puts("\nIntelligent Request Routing:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Advanced routing based on request characteristics:

    defmodule MyApp.SmartRouter do
      def execute(command, args) do
        pool = select_pool(command, args)
        Snakepit.execute(pool, command, args)
      end

      defp select_pool(command, args) do
        cond do
          # Small requests → Process pool (low latency)
          is_small_request?(args) ->
            :api_pool

          # Large data → Thread pool (shared memory)
          has_large_data?(args) ->
            :compute_pool

          # CPU-intensive → Thread pool (parallelism)
          is_cpu_intensive?(command) ->
            :compute_pool

          # Default → Process pool (safe)
          true ->
            :api_pool
        end
      end

      defp is_small_request?(args) do
        byte_size(:erlang.term_to_binary(args)) < 10_000
      end

      defp has_large_data?(args) do
        Map.has_key?(args, :dataset) or Map.has_key?(args, :tensor)
      end

      defp is_cpu_intensive?(command) do
        command in [
          "train_model",
          "compute_intensive",
          "matrix_multiply",
          "batch_process"
        ]
      end
    end
    """)
  end

  defp show_resource_utilization do
    IO.puts("\nResource Utilization:")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Hybrid configuration optimizes total resource usage:

    Single Profile (Process only, 164 workers total):
      Workers: 164 processes
      Memory:  24.6 GB
      Capacity: 164 concurrent requests

    Hybrid (100 process + 4×16 thread = same capacity):
      Workers: 104 processes (100 + 4)
      Memory:  16.6 GB (15 GB + 1.6 GB)
      Capacity: 164 concurrent requests

    Resource Savings:
      Processes: 60 fewer (37% reduction)
      Memory:    8 GB less (33% reduction)
      Performance: BETTER (thread pool faster for CPU tasks)

    This is the recommended production configuration!
    """)
  end

  defp show_real_world_example do
    IO.puts("\nReal-World Example: ML API Service")
    IO.puts(String.duplicate("-", 70))

    IO.puts("""
    Scenario: ML inference API serving two types of requests

    1. Simple predictions (fast, I/O-bound)
       - Input: Small JSON payload (< 10KB)
       - Processing: Pre-loaded model, single inference
       - Duration: 10-50ms
       - Volume: 1000s per second
       → Route to: api_pool (process profile)

    2. Batch inference (slow, CPU-bound)
       - Input: Large batch of images/data (>1MB)
       - Processing: Heavy computation, NumPy operations
       - Duration: 1-10 seconds
       - Volume: 10s per second
       → Route to: compute_pool (thread profile)

    Configuration:
      api_pool:
        - 100 workers (process profile)
        - Handles: 1500 requests/second
        - Memory: 15 GB
        - Cost: High (many processes)

      compute_pool:
        - 4 workers × 16 threads (thread profile)
        - Handles: 64 concurrent batch jobs
        - Memory: 1.6 GB
        - Cost: Low (shared resources)

    Result:
      - Total capacity: 164 concurrent operations
      - Total memory: 16.6 GB (vs 24.6 GB single-profile)
      - Better performance: Right tool for each job
      - Lower cost: Optimized resource usage

    This hybrid approach is THE recommended pattern for production!
    """)
  end
end

# Run the demo
HybridPoolsDemo.run()
