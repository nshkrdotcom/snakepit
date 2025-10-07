#!/usr/bin/env elixir

# Compare performance baseline results

Mix.install([{:jason, "~> 1.4"}])

defmodule ResultsCompare do
  def run(args) do
    case args do
      [file1, file2] ->
        compare(file1, file2)

      [file] ->
        display(file)

      _ ->
        IO.puts("""
        Usage:
          elixir bench/compare_results.exs <result1.json> <result2.json>  # Compare two runs
          elixir bench/compare_results.exs <result.json>                   # Display single run
          elixir bench/compare_results.exs latest                          # Show latest result
        """)
    end
  end

  defp compare(file1, file2) do
    r1 = load_results(file1)
    r2 = load_results(file2)

    IO.puts("\n=== Performance Comparison ===\n")
    IO.puts("Before: #{r1["timestamp"]} (#{file1})")
    IO.puts("After:  #{r2["timestamp"]} (#{file2})\n")

    compare_startup(r1["results"]["startup"], r2["results"]["startup"])
    compare_throughput(r1["results"]["throughput"], r2["results"]["throughput"])
    compare_latency(r1["results"]["latency"], r2["results"]["latency"])
    compare_concurrent(r1["results"]["concurrent"], r2["results"]["concurrent"])

    IO.puts("\n✅ Comparison complete")
  end

  defp display(file) do
    file = if file == "latest", do: get_latest(), else: file
    r = load_results(file)

    IO.puts("\n=== Performance Results ===\n")
    IO.puts("Date: #{r["timestamp"]}")
    IO.puts("Elixir: #{r["elixir_version"]}, OTP: #{r["otp_version"]}")
    IO.puts("Adapter: #{r["adapter"]}\n")

    IO.puts("📊 Startup:")
    for s <- r["results"]["startup"] do
      IO.puts("  Pool #{s["pool_size"]}: #{s["total_ms"]}ms (#{s["per_worker_ms"]}ms/worker)")
    end

    IO.puts("\n📊 Throughput: #{r["results"]["throughput"]["requests_per_second"]} req/s")

    lat = r["results"]["latency"]
    IO.puts("\n📊 Latency: P50=#{lat["p50"]}ms, P95=#{lat["p95"]}ms, P99=#{lat["p99"]}ms")

    IO.puts("\n📊 Concurrent:")
    for c <- r["results"]["concurrent"] do
      IO.puts("  #{c["concurrent"]} workers: #{c["requests_per_second"]} req/s")
    end
  end

  defp compare_startup(before, after_) do
    IO.puts("📊 Startup Performance:")
    Enum.zip(before, after_)
    |> Enum.each(fn {b, a} ->
      diff = a["total_ms"] - b["total_ms"]
      pct = (diff / b["total_ms"]) * 100
      symbol = if diff < 0, do: "✅", else: "⚠️"

      IO.puts("  Pool #{a["pool_size"]}: #{b["total_ms"]}ms → #{a["total_ms"]}ms " <>
              "(#{symbol} #{format_diff(diff)}ms, #{format_pct(pct)})")
    end)
  end

  defp compare_throughput(before, after_) do
    diff = after_["requests_per_second"] - before["requests_per_second"]
    pct = (diff / before["requests_per_second"]) * 100
    symbol = if diff > 0, do: "✅", else: "⚠️"

    IO.puts("\n📊 Throughput:")
    IO.puts("  #{before["requests_per_second"]} → #{after_["requests_per_second"]} req/s " <>
            "(#{symbol} #{format_diff(diff)}, #{format_pct(pct)})")
  end

  defp compare_latency(before, after_) do
    IO.puts("\n📊 Latency:")
    for metric <- ["p50", "p95", "p99"] do
      diff = after_[metric] - before[metric]
      pct = (diff / before[metric]) * 100
      symbol = if diff < 0, do: "✅", else: "⚠️"

      IO.puts("  #{String.upcase(metric)}: #{before[metric]}ms → #{after_[metric]}ms " <>
              "(#{symbol} #{format_diff(diff)}ms, #{format_pct(pct)})")
    end
  end

  defp compare_concurrent(before, after_) do
    IO.puts("\n📊 Concurrent Scaling:")
    Enum.zip(before, after_)
    |> Enum.each(fn {b, a} ->
      diff = a["requests_per_second"] - b["requests_per_second"]
      pct = (diff / b["requests_per_second"]) * 100
      symbol = if diff > 0, do: "✅", else: "⚠️"

      IO.puts("  #{a["concurrent"]} workers: #{b["requests_per_second"]} → #{a["requests_per_second"]} req/s " <>
              "(#{symbol} #{format_diff(diff)}, #{format_pct(pct)})")
    end)
  end

  defp load_results(file) do
    File.read!(file) |> Jason.decode!()
  end

  defp get_latest do
    "bench/results"
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> List.last()
    |> then(&"bench/results/#{&1}")
  end

  defp format_diff(diff) when diff >= 0, do: "+#{Float.round(diff, 2)}"
  defp format_diff(diff), do: Float.round(diff, 2)

  defp format_pct(pct) when pct >= 0, do: "+#{Float.round(pct, 1)}%"
  defp format_pct(pct), do: "#{Float.round(pct, 1)}%"
end

# Run comparison
ResultsCompare.run(System.argv())
