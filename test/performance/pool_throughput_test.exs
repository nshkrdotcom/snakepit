defmodule Snakepit.PoolThroughputTest do
  @moduledoc """
  Performance tests for pool throughput and latency.

  These tests use MockGRPCAdapter for fast, deterministic benchmarking
  without the overhead of real Python processes.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  @moduletag :performance

  setup do
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)
    prev_pool_config = Application.get_env(:snakepit, :pool_config)

    Application.stop(:snakepit)
    Application.load(:snakepit)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(:pools, prev_pools)
      restore_env(:pooling_enabled, prev_pooling)
      restore_env(:pool_config, prev_pool_config)

      assert_eventually(
        fn -> Process.whereis(Snakepit.Pool) == nil end,
        timeout: 5_000,
        interval: 100
      )
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)

  describe "pool throughput benchmarks" do
    setup do
      # Configure pool with MockGRPCAdapter for fast benchmarking
      Application.put_env(:snakepit, :pooling_enabled, true)

      Application.put_env(:snakepit, :pools, [
        %{
          name: :default,
          worker_profile: :process,
          pool_size: 8,
          adapter_module: Snakepit.TestAdapters.MockGRPCAdapter
        }
      ])

      {:ok, _} = Application.ensure_all_started(:snakepit)

      # Wait for pool to be ready
      assert_eventually(
        fn ->
          case Snakepit.Pool.await_ready(Snakepit.Pool, 100) do
            :ok -> true
            _ -> false
          end
        end,
        timeout: 10_000,
        interval: 200
      )

      :ok
    end

    test "measure request latency" do
      # Warm up
      for _ <- 1..10 do
        Snakepit.execute("ping", %{}, timeout: 5_000)
      end

      # Measure latencies
      latencies =
        for _ <- 1..100 do
          start = System.monotonic_time(:microsecond)
          {:ok, _} = Snakepit.execute("ping", %{}, timeout: 5_000)
          System.monotonic_time(:microsecond) - start
        end

      # Calculate statistics
      avg_latency = Enum.sum(latencies) / length(latencies)
      min_latency = Enum.min(latencies)
      max_latency = Enum.max(latencies)

      # Log results
      IO.puts("\nLatency Statistics:")
      IO.puts("  Average: #{Float.round(avg_latency / 1000, 2)}ms")
      IO.puts("  Min: #{Float.round(min_latency / 1000, 2)}ms")
      IO.puts("  Max: #{Float.round(max_latency / 1000, 2)}ms")

      # Assertions - mock adapter should be very fast
      # Average under 10ms
      assert avg_latency < 10_000
      # Max under 50ms
      assert max_latency < 50_000
    end

    test "measure throughput under load" do
      # Number of concurrent clients
      client_count = 20
      requests_per_client = 50

      start_time = System.monotonic_time(:millisecond)

      # Start concurrent clients
      tasks =
        for client_id <- 1..client_count do
          Task.async(fn ->
            for req_id <- 1..requests_per_client do
              {:ok, _} =
                Snakepit.execute("echo", %{client: client_id, request: req_id}, timeout: 10_000)
            end
          end)
        end

      # Wait for all to complete
      Task.await_many(tasks, 30_000)

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time
      total_requests = client_count * requests_per_client
      throughput = total_requests * 1000 / duration

      IO.puts("\nThroughput Results:")
      IO.puts("  Total requests: #{total_requests}")
      IO.puts("  Duration: #{duration}ms")
      IO.puts("  Throughput: #{Float.round(throughput, 1)} req/s")

      # Should handle at least 100 req/s with mock adapter
      assert throughput > 100
    end

    test "pool saturation behavior" do
      # Pool has 8 workers, send 20 slow requests
      slow_request_count = 20
      # 500ms each
      delay = 500

      start_time = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..slow_request_count do
          Task.async(fn ->
            start = System.monotonic_time(:millisecond)
            result = Snakepit.execute("slow_operation", %{delay: delay, id: i}, timeout: 10_000)
            wait_time = System.monotonic_time(:millisecond) - start
            {result, wait_time}
          end)
        end

      results = Task.await_many(tasks, 20_000)
      total_time = System.monotonic_time(:millisecond) - start_time

      # Analyze wait times
      wait_times = Enum.map(results, fn {_, wait_time} -> wait_time end)
      avg_wait = Enum.sum(wait_times) / length(wait_times)

      IO.puts("\nPool Saturation Results:")
      IO.puts("  Pool size: 8")
      IO.puts("  Slow requests: #{slow_request_count}")
      IO.puts("  Request delay: #{delay}ms")
      IO.puts("  Total time: #{total_time}ms")
      IO.puts("  Average wait: #{Float.round(avg_wait, 1)}ms")
      IO.puts("  Theoretical minimum: #{Float.round(slow_request_count * delay / 8, 1)}ms")

      # Should be close to theoretical minimum
      theoretical_min = slow_request_count * delay / 8
      # Allow 50% overhead
      assert total_time < theoretical_min * 1.5
    end
  end
end
