defmodule SnakepitLoadtest.Demos.SustainedLoadDemo do
  @moduledoc """
  Sustained load testing demo that runs continuous load for an extended period.
  """

  alias SnakepitLoadtest

  def run(worker_count \\ 20) do
    IO.puts("\n⏱️  Sustained Load Test Demo")
    IO.puts("============================")
    IO.puts("Workers: #{worker_count}")
    IO.puts("Duration: 2 minutes")
    IO.puts("Workload: Mixed (compute, memory, I/O)\n")

    # Configure for sustained operation
    pool_size = min(worker_count * 2, 40)
    Application.put_env(:snakepit, :pool_config, %{
      pool_size: pool_size,
      max_overflow: 10,
      strategy: :fifo
    })

    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Run sustained load
    results = run_sustained_load(worker_count, 120_000)  # 2 minutes
    
    # Display results
    display_sustained_results(results)
  end

  defp run_sustained_load(worker_count, duration_ms) do
    workload = SnakepitLoadtest.generate_workload(:mixed, %{
      compute_duration: 30,
      sleep: 20
    })
    
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration_ms
    
    # Collect results in intervals
    interval_ms = 10_000  # 10 seconds
    intervals = div(duration_ms, interval_ms)
    
    IO.puts("Running #{intervals} intervals of #{interval_ms}ms each...")
    
    interval_results = 
      1..intervals
      |> Enum.map(fn interval_num ->
        interval_start = System.monotonic_time(:millisecond)
        interval_end = min(interval_start + interval_ms, end_time)
        
        IO.write("\rInterval #{interval_num}/#{intervals}... ")
        
        # Run workers for this interval
        results = run_interval(worker_count, workload, interval_end)
        
        %{
          interval: interval_num,
          duration: System.monotonic_time(:millisecond) - interval_start,
          results: results,
          timestamp: interval_start - start_time
        }
      end)
    
    IO.puts("\nLoad test completed!")
    
    %{
      total_duration: System.monotonic_time(:millisecond) - start_time,
      intervals: interval_results,
      worker_count: worker_count
    }
  end

  defp run_interval(worker_count, workload, end_time) do
    # Continuously spawn workers until end time
    Stream.repeatedly(fn -> :continue end)
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < end_time end)
    |> Stream.chunk_every(worker_count)
    |> Stream.flat_map(fn _chunk ->
      tasks = 
        1..worker_count
        |> Enum.map(fn _ ->
          Task.async(fn ->
            start = System.monotonic_time(:millisecond)
            result = workload.()
            elapsed = System.monotonic_time(:millisecond) - start
            {elapsed, result}
          end)
        end)
      
      # Collect results with timeout
      tasks
      |> Task.yield_many(15000)
      |> Enum.map(fn
        {_task, {:ok, {time, {:ok, _}}}} -> {:success, time}
        {_task, {:ok, {time, {:error, reason}}}} -> {:error, time, reason}
        {task, nil} -> 
          Task.shutdown(task, :brutal_kill)
          {:timeout, nil}
      end)
    end)
    |> Enum.to_list()
  end

  defp display_sustained_results(results) do
    IO.puts("\n📊 Sustained Load Test Results")
    IO.puts("==============================")
    
    # Overall statistics
    display_overall_stats(results)
    
    # Performance over time
    IO.puts("\n📈 Performance Over Time:")
    display_interval_performance(results.intervals)
    
    # Stability analysis
    IO.puts("\n🔍 Stability Analysis:")
    analyze_stability(results.intervals)
  end

  defp display_overall_stats(results) do
    all_results = 
      results.intervals
      |> Enum.flat_map(& &1.results)
    
    successful = Enum.count(all_results, &match?({:success, _}, &1))
    errors = Enum.count(all_results, &match?({:error, _, _}, &1))
    timeouts = Enum.count(all_results, &match?({:timeout, _}, &1))
    
    total = length(all_results)
    
    IO.puts("Total requests: #{total}")
    IO.puts("Successful: #{successful} (#{percentage(successful, total)}%)")
    IO.puts("Errors: #{errors}")
    IO.puts("Timeouts: #{timeouts}")
    IO.puts("Duration: #{format_duration(results.total_duration)}")
    
    throughput = if results.total_duration > 0 do
      successful / (results.total_duration / 1000)
    else
      0
    end
    
    IO.puts("Average throughput: #{format_number(throughput)} req/s")
    
    if successful > 0 do
      all_response_times = 
        all_results
        |> Enum.filter(&match?({:success, _}, &1))
        |> Enum.map(fn {:success, time} -> time end)
      
      stats = SnakepitLoadtest.calculate_stats(all_response_times)
      IO.puts("\nOverall latency statistics:")
      IO.puts(SnakepitLoadtest.format_stats(stats))
    end
  end

  defp display_interval_performance(intervals) do
    intervals
    |> Enum.each(fn interval ->
      successful = Enum.count(interval.results, &match?({:success, _}, &1))
      total = length(interval.results)
      
      if successful > 0 do
        response_times = 
          interval.results
          |> Enum.filter(&match?({:success, _}, &1))
          |> Enum.map(fn {:success, time} -> time end)
        
        stats = SnakepitLoadtest.calculate_stats(response_times)
        
        throughput = if interval.duration > 0 do
          successful / (interval.duration / 1000)
        else
          0
        end
        
        IO.puts("\nInterval #{interval.interval} (#{format_duration(interval.timestamp)}):")
        IO.puts("  Throughput: #{format_number(throughput)} req/s")
        IO.puts("  Success rate: #{percentage(successful, total)}%")
        IO.puts("  Median latency: #{format_number(stats.median)}ms")
        IO.puts("  P95 latency: #{format_number(stats.p95)}ms")
      end
    end)
  end

  defp analyze_stability(intervals) do
    # Calculate variance in performance metrics
    latencies = 
      intervals
      |> Enum.map(fn interval ->
        successful = 
          interval.results
          |> Enum.filter(&match?({:success, _}, &1))
          |> Enum.map(fn {:success, time} -> time end)
        
        if length(successful) > 0 do
          stats = SnakepitLoadtest.calculate_stats(successful)
          stats.median
        else
          nil
        end
      end)
      |> Enum.filter(& &1)
    
    if length(latencies) > 1 do
      latency_stats = SnakepitLoadtest.calculate_stats(latencies)
      
      cv = if latency_stats.mean > 0 do
        (latency_stats.max - latency_stats.min) / latency_stats.mean * 100
      else
        0
      end
      
      IO.puts("Median latency range: #{format_number(latency_stats.min)}ms - #{format_number(latency_stats.max)}ms")
      IO.puts("Coefficient of variation: #{format_number(cv)}%")
      
      cond do
        cv < 20 ->
          IO.puts("✅ Stable performance (low variance)")
        cv < 50 ->
          IO.puts("⚠️  Moderate performance variance")
        true ->
          IO.puts("❌ High performance variance - system may be unstable")
      end
    end
    
    # Check for degradation over time
    if length(intervals) >= 3 do
      first_third = Enum.take(intervals, div(length(intervals), 3))
      last_third = Enum.take(intervals, -div(length(intervals), 3))
      
      first_median = calculate_intervals_median(first_third)
      last_median = calculate_intervals_median(last_third)
      
      if first_median && last_median && first_median > 0 do
        degradation = ((last_median - first_median) / first_median) * 100
        
        IO.puts("\nPerformance trend:")
        IO.puts("  First third median: #{format_number(first_median)}ms")
        IO.puts("  Last third median: #{format_number(last_median)}ms")
        
        sign = if degradation >= 0, do: "+", else: ""
        IO.puts("  Change: #{sign}#{format_number(degradation)}%")
        
        cond do
          abs(degradation) < 10 ->
            IO.puts("  ✅ Performance remains consistent")
          degradation > 0 ->
            IO.puts("  ⚠️  Performance degradation detected")
          true ->
            IO.puts("  ✅ Performance improvement over time")
        end
      end
    end
  end

  defp calculate_intervals_median(intervals) do
    all_times = 
      intervals
      |> Enum.flat_map(fn interval ->
        interval.results
        |> Enum.filter(&match?({:success, _}, &1))
        |> Enum.map(fn {:success, time} -> time end)
      end)
    
    if length(all_times) > 0 do
      stats = SnakepitLoadtest.calculate_stats(all_times)
      stats.median
    else
      nil
    end
  end

  defp percentage(part, whole) when whole > 0, do: round(part / whole * 100)
  defp percentage(_, _), do: 0

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n), do: to_string(n)

  defp format_duration(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    
    if minutes > 0 do
      "#{minutes}m #{remaining_seconds}s"
    else
      "#{seconds}s"
    end
  end
end