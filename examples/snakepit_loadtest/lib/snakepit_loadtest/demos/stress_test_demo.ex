defmodule SnakepitLoadtest.Demos.StressTestDemo do
  @moduledoc """
  Stress test demo that pushes the system to its limits with heavy workloads.
  """

  alias SnakepitLoadtest

  def run(worker_count \\ 50) do
    IO.puts("\n💥 Stress Test Demo")
    IO.puts("===================")
    IO.puts("Workers: #{worker_count}")
    IO.puts("Workload: Memory-intensive + compute tasks")
    IO.puts("Duration: ~60 seconds\n")

    # Configure for stress testing
    pool_size = min(div(worker_count, 2), 100)
    Application.put_env(:snakepit, :pool_config, %{
      pool_size: pool_size,
      max_overflow: 20,
      strategy: :fifo
    })

    {:ok, _} = Application.ensure_all_started(:snakepit)

    # Run different stress scenarios
    IO.puts("Phase 1: Memory pressure test...")
    memory_results = stress_memory(worker_count)
    
    Process.sleep(2000)  # Brief cooldown
    
    IO.puts("\nPhase 2: CPU intensive test...")
    cpu_results = stress_cpu(worker_count)
    
    Process.sleep(2000)  # Brief cooldown
    
    IO.puts("\nPhase 3: Mixed workload test...")
    mixed_results = stress_mixed(worker_count)

    # Display combined results
    display_stress_results(%{
      memory: memory_results,
      cpu: cpu_results,
      mixed: mixed_results
    })
  end

  defp stress_memory(worker_count) do
    workload = SnakepitLoadtest.generate_workload(:memory, %{
      duration: 100
    })
    
    execute_stress_test(worker_count, workload, "Memory")
  end

  defp stress_cpu(worker_count) do
    workload = SnakepitLoadtest.generate_workload(:compute, %{
      duration: 200
    })
    
    execute_stress_test(worker_count, workload, "CPU")
  end

  defp stress_mixed(worker_count) do
    workload = SnakepitLoadtest.generate_workload(:mixed, %{
      compute_duration: 50,
      sleep: 5
    })
    
    execute_stress_test(worker_count, workload, "Mixed")
  end

  defp execute_stress_test(worker_count, workload, phase_name) do
    start_time = System.monotonic_time(:millisecond)
    
    # Launch workers in waves
    waves = 5
    workers_per_wave = div(worker_count, waves)
    
    results = 
      1..waves
      |> Enum.flat_map(fn wave ->
        IO.write("  Wave #{wave}/#{waves}...")
        
        wave_results = 
          1..workers_per_wave
          |> Task.async_stream(
            fn worker_id ->
              global_id = (wave - 1) * workers_per_wave + worker_id
              {time, result} = SnakepitLoadtest.time_execution(workload)
              {global_id, time, result}
            end,
            max_concurrency: workers_per_wave,
            timeout: 60000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, {id, time, {:ok, _}}} -> {:success, id, time}
            {:ok, {id, time, {:error, reason}}} -> {:error, id, time, reason}
            {:exit, :timeout} -> {:timeout, nil, nil}
            {:exit, reason} -> {:crash, nil, nil, reason}
          end)
        
        IO.puts(" done")
        Process.sleep(500)  # Small delay between waves
        wave_results
      end)
    
    total_time = System.monotonic_time(:millisecond) - start_time
    
    %{
      phase: phase_name,
      results: results,
      total_time: total_time,
      worker_count: worker_count
    }
  end

  defp display_stress_results(all_results) do
    IO.puts("\n📈 Stress Test Results")
    IO.puts("======================")
    
    Enum.each([:memory, :cpu, :mixed], fn phase ->
      results = Map.get(all_results, phase)
      display_phase_results(results)
    end)
    
    IO.puts("\n🔍 System Impact Analysis")
    IO.puts("=========================")
    analyze_system_impact(all_results)
  end

  defp display_phase_results(%{phase: phase, results: results, total_time: total_time, worker_count: worker_count}) do
    successful = Enum.filter(results, &match?({:success, _, _}, &1))
    errors = Enum.filter(results, &match?({:error, _, _, _}, &1))
    timeouts = Enum.filter(results, &match?({:timeout, _, _}, &1))
    
    success_count = length(successful)
    error_count = length(errors)
    timeout_count = length(timeouts)
    
    IO.puts("\n#{phase} Phase:")
    IO.puts("  Success rate: #{percentage(success_count, worker_count)}%")
    IO.puts("  Errors: #{error_count}, Timeouts: #{timeout_count}")
    IO.puts("  Total time: #{total_time}ms")
    
    if success_count > 0 do
      response_times = Enum.map(successful, fn {:success, _, time} -> time end)
      stats = SnakepitLoadtest.calculate_stats(response_times)
      IO.puts("  Median response: #{format_number(stats.median)}ms")
      IO.puts("  P95 response: #{format_number(stats.p95)}ms")
    end
  end

  defp analyze_system_impact(all_results) do
    # Calculate degradation across phases
    memory_median = get_median_response(all_results.memory)
    cpu_median = get_median_response(all_results.cpu)
    mixed_median = get_median_response(all_results.mixed)
    
    if memory_median && cpu_median && mixed_median do
      IO.puts("Response time degradation:")
      IO.puts("  Memory → CPU: #{format_degradation(memory_median, cpu_median)}")
      IO.puts("  CPU → Mixed: #{format_degradation(cpu_median, mixed_median)}")
      IO.puts("  Overall: #{format_degradation(memory_median, mixed_median)}")
    end
    
    # Success rate analysis
    memory_success = calculate_success_rate(all_results.memory)
    cpu_success = calculate_success_rate(all_results.cpu)
    mixed_success = calculate_success_rate(all_results.mixed)
    
    IO.puts("\nSuccess rate trend:")
    IO.puts("  Memory: #{memory_success}%")
    IO.puts("  CPU: #{cpu_success}%")
    IO.puts("  Mixed: #{mixed_success}%")
    
    if mixed_success < 90 do
      IO.puts("\n⚠️  Warning: Success rate below 90% indicates system stress")
    end
  end

  defp get_median_response(%{results: results}) do
    successful = Enum.filter(results, &match?({:success, _, _}, &1))
    if length(successful) > 0 do
      response_times = Enum.map(successful, fn {:success, _, time} -> time end)
      stats = SnakepitLoadtest.calculate_stats(response_times)
      stats.median
    else
      nil
    end
  end

  defp calculate_success_rate(%{results: results, worker_count: worker_count}) do
    success_count = Enum.count(results, &match?({:success, _, _}, &1))
    percentage(success_count, worker_count)
  end

  defp format_degradation(base, current) when base > 0 do
    degradation = ((current - base) / base) * 100
    sign = if degradation >= 0, do: "+", else: ""
    "#{sign}#{format_number(degradation)}%"
  end
  defp format_degradation(_, _), do: "N/A"

  defp percentage(part, whole) when whole > 0, do: round(part / whole * 100)
  defp percentage(_, _), do: 0

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_number(n), do: to_string(n)
end