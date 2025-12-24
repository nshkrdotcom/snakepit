defmodule SnakepitLoadtest.Demos.BurstLoadDemo do
  @moduledoc """
  Burst load testing demo that simulates sudden spikes in traffic.
  """

  alias SnakepitLoadtest

  def run(peak_workers \\ 100) do
    IO.puts("\n⚡ Burst Load Test Demo")
    IO.puts("=======================")
    IO.puts("Peak workers: #{peak_workers}")
    IO.puts("Pattern: Gradual ramp-up → Peak burst → Cool down")
    IO.puts("Duration: ~45 seconds\n")

    # Configure for burst handling - start with smaller pool to avoid eagain
    # Start with max 10 workers
    pool_size = min(div(peak_workers, 10), 10)
    IO.puts("Pool size: #{pool_size} workers")

    # Don't restart Snakepit - just use the existing pool
    # The pool is already configured from config.exs with showcase adapter

    # Execute burst pattern
    results = execute_burst_pattern(peak_workers)

    # Display results
    display_burst_results(results)
  end

  defp execute_burst_pattern(peak_workers) do
    phases = [
      # Warm-up phase
      %{name: "Warm-up", workers: 5, duration: 5000, delay: 100},

      # Ramp-up phase
      %{name: "Ramp-up 25%", workers: div(peak_workers, 4), duration: 3000, delay: 50},
      %{name: "Ramp-up 50%", workers: div(peak_workers, 2), duration: 3000, delay: 25},
      %{name: "Ramp-up 75%", workers: div(peak_workers * 3, 4), duration: 3000, delay: 10},

      # Peak burst
      %{name: "Peak Burst", workers: peak_workers, duration: 5000, delay: 0},

      # Sustained peak
      %{name: "Sustained Peak", workers: peak_workers, duration: 10000, delay: 5},

      # Cool down
      %{name: "Cool-down 50%", workers: div(peak_workers, 2), duration: 5000, delay: 25},
      %{name: "Cool-down 25%", workers: div(peak_workers, 4), duration: 5000, delay: 50},
      %{name: "Idle", workers: 5, duration: 3000, delay: 100}
    ]

    workload = SnakepitLoadtest.generate_workload(:compute, %{duration: 30})

    Enum.map(phases, fn phase ->
      IO.puts("Phase: #{phase.name} (#{phase.workers} workers)...")
      execute_phase(phase, workload)
    end)
  end

  defp execute_phase(phase, workload) do
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + phase.duration

    # Launch workers continuously during the phase
    results =
      launch_workers_continuously(
        phase.workers,
        workload,
        end_time,
        phase.delay
      )

    actual_duration = System.monotonic_time(:millisecond) - start_time

    %{
      phase: phase.name,
      target_workers: phase.workers,
      actual_requests: length(results),
      duration: actual_duration,
      results: results
    }
  end

  defp launch_workers_continuously(worker_count, workload, end_time, delay) do
    Stream.repeatedly(fn -> :continue end)
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < end_time end)
    |> Stream.map(fn _ ->
      # Launch a batch of workers
      tasks =
        1..worker_count
        |> Enum.map(fn _ ->
          Task.async(fn ->
            {time, result} = SnakepitLoadtest.time_execution(workload)
            {time, result}
          end)
        end)

      # Wait for completion with timeout
      results =
        tasks
        |> Task.yield_many(10000)
        |> Enum.map(fn
          {_task, {:ok, {time, {:ok, _}}}} ->
            {:success, time}

          {_task, {:ok, {time, {:error, reason}}}} ->
            {:error, time, reason}

          {task, nil} ->
            Task.shutdown(task, :brutal_kill)
            {:timeout, nil}
        end)

      if delay > 0, do: wait_delay(delay)

      results
    end)
    |> Enum.flat_map(& &1)
  end

  defp wait_delay(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    receive do
    after
      delay_ms -> :ok
    end
  end

  defp display_burst_results(phase_results) do
    IO.puts("\n📊 Burst Test Results")
    IO.puts("=====================")

    # Phase-by-phase analysis
    IO.puts("\nPhase Analysis:")
    Enum.each(phase_results, &display_phase_summary/1)

    # Overall performance metrics
    IO.puts("\n📈 Performance Metrics:")
    calculate_overall_metrics(phase_results)

    # Burst handling analysis
    IO.puts("\n💥 Burst Handling Analysis:")
    analyze_burst_handling(phase_results)
  end

  defp display_phase_summary(phase_result) do
    successful = Enum.count(phase_result.results, &match?({:success, _}, &1))
    errors = Enum.count(phase_result.results, &match?({:error, _, _}, &1))
    timeouts = Enum.count(phase_result.results, &match?({:timeout, _}, &1))

    total = length(phase_result.results)
    success_rate = if total > 0, do: round(successful / total * 100), else: 0

    throughput =
      if phase_result.duration > 0 do
        successful / (phase_result.duration / 1000)
      else
        0
      end

    IO.puts("\n#{phase_result.phase}:")
    IO.puts("  Requests: #{total} (#{success_rate}% success)")
    IO.puts("  Throughput: #{format_number(throughput)} req/s")

    if successful > 0 do
      response_times =
        phase_result.results
        |> Enum.filter(&match?({:success, _}, &1))
        |> Enum.map(fn {:success, time} -> time end)

      if length(response_times) > 0 do
        stats = SnakepitLoadtest.calculate_stats(response_times)
        IO.puts("  Median latency: #{format_number(stats.median)}ms")
        IO.puts("  P95 latency: #{format_number(stats.p95)}ms")
      end
    end

    if errors + timeouts > 0 do
      IO.puts("  Errors: #{errors}, Timeouts: #{timeouts}")
    end
  end

  defp calculate_overall_metrics(phase_results) do
    all_successes =
      phase_results
      |> Enum.flat_map(fn phase ->
        phase.results
        |> Enum.filter(&match?({:success, _}, &1))
        |> Enum.map(fn {:success, time} -> time end)
      end)

    total_requests =
      phase_results
      |> Enum.map(fn phase -> length(phase.results) end)
      |> Enum.sum()

    total_duration =
      phase_results
      |> Enum.map(& &1.duration)
      |> Enum.sum()

    if length(all_successes) > 0 do
      stats = SnakepitLoadtest.calculate_stats(all_successes)

      IO.puts("Total requests: #{total_requests}")
      IO.puts("Successful requests: #{length(all_successes)}")
      IO.puts("Overall success rate: #{round(length(all_successes) / total_requests * 100)}%")

      IO.puts(
        "Average throughput: #{format_number(length(all_successes) / (total_duration / 1000))} req/s"
      )

      IO.puts("\nLatency across all phases:")
      IO.puts(SnakepitLoadtest.format_stats(stats))
    end
  end

  defp analyze_burst_handling(phase_results) do
    # Find peak burst phase
    peak_phase = Enum.find(phase_results, fn phase -> phase.phase == "Peak Burst" end)
    sustained_phase = Enum.find(phase_results, fn phase -> phase.phase == "Sustained Peak" end)

    if peak_phase && sustained_phase do
      peak_success_rate = calculate_phase_success_rate(peak_phase)
      sustained_success_rate = calculate_phase_success_rate(sustained_phase)

      IO.puts("Peak burst success rate: #{peak_success_rate}%")
      IO.puts("Sustained peak success rate: #{sustained_success_rate}%")

      degradation = sustained_success_rate - peak_success_rate

      if degradation < -10 do
        IO.puts("Note: Significant degradation under sustained load (#{abs(degradation)}% drop)")
      else
        IO.puts("✅ System handles sustained peak load well")
      end

      # Analyze recovery
      cooldown_phase = Enum.find(phase_results, fn phase -> phase.phase == "Cool-down 50%" end)

      if cooldown_phase do
        cooldown_latency = get_phase_median_latency(cooldown_phase)
        peak_latency = get_phase_median_latency(peak_phase)

        if cooldown_latency && peak_latency do
          recovery_factor = peak_latency / cooldown_latency
          IO.puts("\nRecovery performance:")
          IO.puts("  Latency improvement: #{format_number(recovery_factor)}x")

          if recovery_factor > 1.5 do
            IO.puts("  ✅ Good recovery characteristics")
          else
            IO.puts("  Note: Slow recovery from peak load")
          end
        end
      end
    end
  end

  defp calculate_phase_success_rate(phase) do
    successful = Enum.count(phase.results, &match?({:success, _}, &1))
    total = length(phase.results)
    if total > 0, do: round(successful / total * 100), else: 0
  end

  defp get_phase_median_latency(phase) do
    response_times =
      phase.results
      |> Enum.filter(&match?({:success, _}, &1))
      |> Enum.map(fn {:success, time} -> time end)

    if length(response_times) > 0 do
      stats = SnakepitLoadtest.calculate_stats(response_times)
      stats.median
    else
      nil
    end
  end

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n), do: to_string(n)
end
