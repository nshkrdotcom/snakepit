defmodule SnakepitLoadtest do
  @moduledoc """
  Load testing suite for Snakepit Python integration.
  
  Provides various load testing scenarios to stress test the Python process pool
  and measure performance characteristics under different load patterns.
  """

  @doc """
  Get statistics for a list of measurements.
  """
  def calculate_stats(measurements) when is_list(measurements) and length(measurements) > 0 do
    sorted = Enum.sort(measurements)
    count = length(sorted)
    
    %{
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Enum.sum(sorted) / count,
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, round(count * 0.95)),
      p99: Enum.at(sorted, round(count * 0.99))
    }
  end

  @doc """
  Format statistics for display.
  """
  def format_stats(stats, unit \\ "ms") do
    """
    Min: #{format_number(stats.min)}#{unit}
    Max: #{format_number(stats.max)}#{unit}
    Mean: #{format_number(stats.mean)}#{unit}
    Median: #{format_number(stats.median)}#{unit}
    P95: #{format_number(stats.p95)}#{unit}
    P99: #{format_number(stats.p99)}#{unit}
    """
  end

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n), do: to_string(n)

  @doc """
  Execute a function with timing.
  """
  def time_execution(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {elapsed, result}
  end

  @doc """
  Generate a workload function.
  """
  def generate_workload(type, options \\ %{}) do
    case type do
      :compute ->
        fn ->
          # Use cpu_bound_task from ShowcaseAdapter
          Snakepit.execute("cpu_bound_task", %{
            task_id: "compute_#{System.unique_integer([:positive])}",
            duration_ms: options[:duration] || 50
          })
        end
      
      :sleep ->
        fn ->
          # Use sleep_task from ShowcaseAdapter
          Snakepit.execute("sleep_task", %{
            duration_ms: options[:duration] || 100,
            task_number: System.unique_integer([:positive])
          })
        end
      
      :memory ->
        fn ->
          # Use cpu_bound_task with longer duration to simulate memory work
          Snakepit.execute("cpu_bound_task", %{
            task_id: "memory_#{System.unique_integer([:positive])}",
            duration_ms: options[:duration] || 100
          })
        end
      
      :io ->
        fn ->
          # Use lightweight_task for IO simulation
          Snakepit.execute("lightweight_task", %{
            iteration: System.unique_integer([:positive])
          })
        end
      
      :mixed ->
        fn ->
          # Use a combination of cpu_bound_task and sleep_task
          task_id = System.unique_integer([:positive])
          cpu_result = Snakepit.execute("cpu_bound_task", %{
            task_id: "mixed_cpu_#{task_id}",
            duration_ms: options[:compute_duration] || 20
          })
          
          case cpu_result do
            {:ok, _} ->
              Snakepit.execute("sleep_task", %{
                duration_ms: options[:sleep] || 10,
                task_number: task_id
              })
            error -> error
          end
        end
    end
  end
end