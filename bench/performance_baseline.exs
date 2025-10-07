#!/usr/bin/env elixir

# Simple Performance Baseline for Snakepit
# Tracks key metrics: startup time, throughput, latency

Mix.install([
  {:snakepit, path: "."},
  {:jason, "~> 1.4"}
])

defmodule SnakepitBenchmark do
  @pool_sizes [2, 4, 8, 16]
  @iterations 100

  def run do
    IO.puts("\n=== Snakepit Performance Baseline ===\n")
    IO.puts("Date: #{DateTime.utc_now()}")
    IO.puts("Elixir: #{System.version()}")
    IO.puts("OTP: #{System.otp_release()}\n")

    results = %{
      startup: benchmark_startup(),
      throughput: benchmark_throughput(),
      latency: benchmark_latency(),
      concurrent: benchmark_concurrent()
    }

    save_results(results)
    display_summary(results)
  end

  defp benchmark_startup do
    IO.puts("\n📊 Startup Performance (Concurrent Initialization)")
    IO.puts("---------------------------------------------------")

    Enum.map(@pool_sizes, fn size ->
      # Ensure clean state
      Application.stop(:snakepit)
      :timer.sleep(100)

      # Configure pool size
      Application.put_env(:snakepit, :pool_config, %{pool_size: size})
      Application.put_env(:snakepit, :pooling_enabled, true)

      # Measure startup
      {time_us, {:ok, _}} = :timer.tc(fn ->
        {:ok, _} = Application.ensure_all_started(:snakepit)
        # Wait for all workers ready
        :timer.sleep(1000)
        Snakepit.execute("ping", %{})
      end)

      time_ms = time_us / 1000
      time_per_worker = time_ms / size

      IO.puts("  Pool size #{size}: #{Float.round(time_ms, 2)}ms total, #{Float.round(time_per_worker, 2)}ms per worker")

      %{
        pool_size: size,
        total_ms: Float.round(time_ms, 2),
        per_worker_ms: Float.round(time_per_worker, 2),
        speedup: if(size > 1, do: Float.round(size / (time_ms / 1000), 1), else: 1.0)
      }
    end)
  end

  defp benchmark_throughput do
    IO.puts("\n📊 Throughput (requests/second)")
    IO.puts("--------------------------------")

    # Ensure snakepit running with good pool size
    Application.stop(:snakepit)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 8})
    {:ok, _} = Application.ensure_all_started(:snakepit)
    :timer.sleep(1000)

    {time_us, _} = :timer.tc(fn ->
      1..@iterations
      |> Task.async_stream(fn _i ->
        Snakepit.execute("ping", %{})
      end, max_concurrency: 20, timeout: 30_000)
      |> Enum.to_list()
    end)

    time_s = time_us / 1_000_000
    rps = @iterations / time_s

    IO.puts("  #{@iterations} requests in #{Float.round(time_s, 2)}s = #{Float.round(rps, 2)} req/s")

    %{
      total_requests: @iterations,
      duration_s: Float.round(time_s, 2),
      requests_per_second: Float.round(rps, 2)
    }
  end

  defp benchmark_latency do
    IO.puts("\n📊 Latency Distribution")
    IO.puts("------------------------")

    latencies =
      1..50
      |> Enum.map(fn _ ->
        {time_us, _} = :timer.tc(fn ->
          Snakepit.execute("ping", %{})
        end)
        time_us / 1000  # Convert to ms
      end)

    sorted = Enum.sort(latencies)
    p50 = percentile(sorted, 50)
    p95 = percentile(sorted, 95)
    p99 = percentile(sorted, 99)
    avg = Enum.sum(latencies) / length(latencies)
    min = Enum.min(latencies)
    max = Enum.max(latencies)

    IO.puts("  Min: #{Float.round(min, 2)}ms")
    IO.puts("  Avg: #{Float.round(avg, 2)}ms")
    IO.puts("  P50: #{Float.round(p50, 2)}ms")
    IO.puts("  P95: #{Float.round(p95, 2)}ms")
    IO.puts("  P99: #{Float.round(p99, 2)}ms")
    IO.puts("  Max: #{Float.round(max, 2)}ms")

    %{
      min: Float.round(min, 2),
      avg: Float.round(avg, 2),
      p50: Float.round(p50, 2),
      p95: Float.round(p95, 2),
      p99: Float.round(p99, 2),
      max: Float.round(max, 2)
    }
  end

  defp benchmark_concurrent do
    IO.puts("\n📊 Concurrent Workers (scaling)")
    IO.puts("--------------------------------")

    Enum.map([10, 50, 100], fn concurrent ->
      {time_us, _} = :timer.tc(fn ->
        1..concurrent
        |> Task.async_stream(fn _i ->
          Snakepit.execute("ping", %{})
        end, max_concurrency: concurrent, timeout: 30_000)
        |> Enum.to_list()
      end)

      time_ms = time_us / 1000
      rps = concurrent / (time_us / 1_000_000)

      IO.puts("  #{concurrent} concurrent: #{Float.round(time_ms, 2)}ms, #{Float.round(rps, 2)} req/s")

      %{
        concurrent: concurrent,
        total_ms: Float.round(time_ms, 2),
        requests_per_second: Float.round(rps, 2)
      }
    end)
  end

  defp percentile(sorted_list, p) do
    index = round(length(sorted_list) * p / 100) - 1
    index = max(0, min(index, length(sorted_list) - 1))
    Enum.at(sorted_list, index)
  end

  defp save_results(results) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = "bench/results/baseline_#{timestamp}.json"

    File.mkdir_p!("bench/results")

    data = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      elixir_version: System.version(),
      otp_version: System.otp_release(),
      adapter: "ShowcaseAdapter",
      results: results
    }

    File.write!(filename, Jason.encode!(data, pretty: true))
    IO.puts("\n✅ Results saved to: #{filename}")
  end

  defp display_summary(results) do
    IO.puts("\n=== Summary ===")
    IO.puts("✅ Startup: #{length(results.startup)} pool sizes tested")
    IO.puts("✅ Throughput: #{results.throughput.requests_per_second} req/s")
    IO.puts("✅ Latency P50: #{results.latency.p50}ms, P99: #{results.latency.p99}ms")
    IO.puts("✅ Scaling: #{List.last(results.concurrent).concurrent} concurrent requests handled")
    IO.puts("\nPerformance baseline complete! 🚀")
  end
end

# Run benchmark
SnakepitBenchmark.run()

# Clean shutdown
Application.stop(:snakepit)
