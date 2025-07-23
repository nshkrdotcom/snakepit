defmodule SnakepitLoadtest.Demos.BasicLoadDemo do
  @moduledoc """
  Basic load testing demo that spawns a configurable number of concurrent workers.
  """

  alias SnakepitLoadtest
  require Logger

  def run(worker_count \\ 10) do
    IO.puts("\n🚀 Basic Load Test Demo")
    IO.puts("=======================")
    IO.puts("Workers: #{worker_count}")
    IO.puts("Workload: Simple compute tasks\n")

    # Get the current pool size
    pool_config = Application.get_env(:snakepit, :pool_config, %{})
    current_pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)
    
    # Use configured pool size instead of trying to reconfigure
    actual_pool_size = min(current_pool_size, worker_count)
    
    if worker_count > current_pool_size do
      IO.puts("⚠️  Note: Requested #{worker_count} workers but pool is configured for #{current_pool_size}")
      IO.puts("   Using #{actual_pool_size} workers for this test")
      IO.puts("   To use more workers, configure pool_size in config.exs\n")
    end
    
    # Ensure Snakepit is started
    case Application.ensure_all_started(:snakepit) do
      {:ok, _} -> :ok
      {:error, {:already_started, :snakepit}} -> :ok
      error -> raise "Failed to start Snakepit: #{inspect(error)}"
    end
    
    # Warm up the pool
    IO.puts("Warming up pool...")
    warm_up_pool(actual_pool_size)

    # Run the load test
    IO.puts("\nStarting load test...")
    results = run_concurrent_workers(worker_count)

    # Display results
    display_results(results, worker_count)
  end

  defp warm_up_pool(pool_size) do
    1..pool_size
    |> Task.async_stream(
      fn _ -> Snakepit.execute("ping", %{message: "warmup"}) end,
      max_concurrency: pool_size,
      timeout: 30000  # Increased timeout to 30 seconds for gRPC startup
    )
    |> Stream.run()
  end

  defp run_concurrent_workers(worker_count) do
    workload = SnakepitLoadtest.generate_workload(:compute, %{duration: 50})
    
    start_time = System.monotonic_time(:millisecond)
    
    results = 
      1..worker_count
      |> Task.async_stream(
        fn worker_id ->
          {time, result} = SnakepitLoadtest.time_execution(workload)
          {worker_id, time, result}
        end,
        max_concurrency: worker_count,
        timeout: 30000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {worker_id, time, {:ok, _result}}} ->
          {:success, worker_id, time}
        
        {:ok, {worker_id, time, {:error, reason}}} ->
          {:error, worker_id, time, reason}
        
        {:exit, :timeout} ->
          {:timeout, nil, nil}
        
        {:exit, reason} ->
          {:crash, nil, nil, reason}
      end)
    
    total_time = System.monotonic_time(:millisecond) - start_time
    
    %{
      results: results,
      total_time: total_time,
      start_time: start_time
    }
  end

  defp display_results(%{results: results, total_time: total_time}, worker_count) do
    successful = Enum.filter(results, &match?({:success, _, _}, &1))
    errors = Enum.filter(results, &match?({:error, _, _, _}, &1))
    timeouts = Enum.filter(results, &match?({:timeout, _, _}, &1))
    crashes = Enum.filter(results, &match?({:crash, _, _, _}, &1))

    success_count = length(successful)
    error_count = length(errors)
    timeout_count = length(timeouts)
    crash_count = length(crashes)

    IO.puts("\n📊 Results Summary")
    IO.puts("==================")
    IO.puts("Total workers: #{worker_count}")
    IO.puts("Successful: #{success_count} (#{percentage(success_count, worker_count)}%)")
    IO.puts("Errors: #{error_count}")
    IO.puts("Timeouts: #{timeout_count}")
    IO.puts("Crashes: #{crash_count}")
    IO.puts("Total time: #{total_time}ms")
    IO.puts("Throughput: #{format_throughput(success_count, total_time)} req/s")

    if success_count > 0 do
      response_times = Enum.map(successful, fn {:success, _, time} -> time end)
      stats = SnakepitLoadtest.calculate_stats(response_times)
      
      IO.puts("\n⏱️  Response Time Statistics")
      IO.puts("============================")
      IO.puts(SnakepitLoadtest.format_stats(stats))
    end

    if error_count > 0 do
      IO.puts("\n❌ Errors:")
      errors
      |> Enum.take(5)
      |> Enum.each(fn {:error, worker_id, _time, reason} ->
        IO.puts("   Worker #{worker_id}: #{inspect(reason)}")
      end)
      
      if error_count > 5 do
        IO.puts("   ... and #{error_count - 5} more errors")
      end
    end
  end

  defp percentage(part, whole) when whole > 0 do
    round(part / whole * 100)
  end
  defp percentage(_, _), do: 0

  defp format_throughput(count, time_ms) when time_ms > 0 do
    throughput = count / (time_ms / 1000)
    :erlang.float_to_binary(throughput, decimals: 2)
  end
  defp format_throughput(_, _), do: "0.00"
end