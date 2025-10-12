defmodule Snakepit.Diagnostics.ProfileInspector do
  @moduledoc """
  Programmatic inspection of pool profiles and worker statistics.

  This module provides functions to analyze pool configurations, worker profiles,
  capacity utilization, memory usage, and performance metrics for both process
  and thread profile workers.

  ## Features

  - Pool configuration inspection
  - Worker profile analysis (process vs thread)
  - Capacity utilization metrics
  - Memory usage per worker
  - Thread usage for thread profile pools
  - Performance statistics

  ## Examples

      # Get statistics for a specific pool
      {:ok, stats} = ProfileInspector.get_pool_stats(:default)

      # Analyze capacity utilization
      {:ok, capacity} = ProfileInspector.get_capacity_stats(:hpc_pool)

      # Get memory usage breakdown
      {:ok, memory} = ProfileInspector.get_memory_stats(:default)

      # Get comprehensive report for all pools
      {:ok, report} = ProfileInspector.get_comprehensive_report()
  """

  require Logger
  alias Snakepit.Config

  @type pool_name :: atom()
  @type pool_stats :: %{
          pool_name: pool_name(),
          profile: :process | :thread,
          worker_count: non_neg_integer(),
          capacity_total: non_neg_integer(),
          capacity_used: non_neg_integer(),
          capacity_available: non_neg_integer(),
          utilization_percent: float(),
          workers: [worker_stats()]
        }

  @type worker_stats :: %{
          worker_id: String.t(),
          pid: pid(),
          profile: :process | :thread,
          capacity: pos_integer(),
          load: non_neg_integer(),
          memory_mb: float(),
          status: :available | :busy | :unknown
        }

  @type capacity_stats :: %{
          total_capacity: non_neg_integer(),
          used_capacity: non_neg_integer(),
          available_capacity: non_neg_integer(),
          utilization_percent: float(),
          thread_info: thread_info() | nil
        }

  @type thread_info :: %{
          workers: non_neg_integer(),
          threads_per_worker: pos_integer(),
          total_threads: non_neg_integer(),
          avg_load_per_worker: float()
        }

  @type memory_stats :: %{
          total_memory_mb: float(),
          avg_memory_per_worker_mb: float(),
          max_memory_worker_mb: float(),
          min_memory_worker_mb: float(),
          workers: [{String.t(), float()}]
        }

  @doc """
  Get comprehensive statistics for a specific pool.

  Returns detailed information about the pool's configuration, workers,
  capacity utilization, and performance metrics.

  ## Examples

      iex> ProfileInspector.get_pool_stats(:default)
      {:ok, %{
        pool_name: :default,
        profile: :process,
        worker_count: 100,
        capacity_total: 100,
        capacity_used: 45,
        capacity_available: 55,
        utilization_percent: 45.0,
        workers: [...]
      }}
  """
  @spec get_pool_stats(pool_name()) :: {:ok, pool_stats()} | {:error, term()}
  def get_pool_stats(pool_name \\ :default) do
    with {:ok, config} <- Config.get_pool_config(pool_name),
         {:ok, workers} <- get_pool_workers(pool_name) do
      profile = Map.get(config, :worker_profile, :process)
      profile_module = Config.get_profile_module(config)

      # Gather statistics for each worker
      worker_stats =
        Enum.map(workers, fn worker_id ->
          get_worker_stats(worker_id, profile_module)
        end)
        |> Enum.reject(&is_nil/1)

      # Calculate aggregate statistics
      total_capacity = Enum.sum(Enum.map(worker_stats, & &1.capacity))
      used_capacity = Enum.sum(Enum.map(worker_stats, & &1.load))
      available_capacity = total_capacity - used_capacity

      utilization =
        if total_capacity > 0 do
          used_capacity / total_capacity * 100
        else
          0.0
        end

      stats = %{
        pool_name: pool_name,
        profile: profile,
        worker_count: length(worker_stats),
        capacity_total: total_capacity,
        capacity_used: used_capacity,
        capacity_available: available_capacity,
        utilization_percent: Float.round(utilization, 2),
        workers: worker_stats
      }

      {:ok, stats}
    end
  end

  @doc """
  Get capacity statistics for a pool.

  Returns information about total capacity, utilization, and thread-specific
  metrics for thread profile pools.

  ## Examples

      iex> ProfileInspector.get_capacity_stats(:hpc_pool)
      {:ok, %{
        total_capacity: 64,
        used_capacity: 42,
        available_capacity: 22,
        utilization_percent: 65.6,
        thread_info: %{
          workers: 4,
          threads_per_worker: 16,
          total_threads: 64,
          avg_load_per_worker: 10.5
        }
      }}
  """
  @spec get_capacity_stats(pool_name()) :: {:ok, capacity_stats()} | {:error, term()}
  def get_capacity_stats(pool_name \\ :default) do
    with {:ok, pool_stats} <- get_pool_stats(pool_name) do
      capacity = %{
        total_capacity: pool_stats.capacity_total,
        used_capacity: pool_stats.capacity_used,
        available_capacity: pool_stats.capacity_available,
        utilization_percent: pool_stats.utilization_percent,
        thread_info: build_thread_info(pool_stats)
      }

      {:ok, capacity}
    end
  end

  @doc """
  Get memory statistics for a pool.

  Returns aggregate and per-worker memory usage statistics.

  ## Examples

      iex> ProfileInspector.get_memory_stats(:default)
      {:ok, %{
        total_memory_mb: 2048.5,
        avg_memory_per_worker_mb: 20.5,
        max_memory_worker_mb: 45.2,
        min_memory_worker_mb: 15.8,
        workers: [{"worker_1", 20.5}, ...]
      }}
  """
  @spec get_memory_stats(pool_name()) :: {:ok, memory_stats()} | {:error, term()}
  def get_memory_stats(pool_name \\ :default) do
    with {:ok, pool_stats} <- get_pool_stats(pool_name) do
      worker_memories = Enum.map(pool_stats.workers, fn w -> {w.worker_id, w.memory_mb} end)
      memory_values = Enum.map(worker_memories, fn {_id, mem} -> mem end)

      total = Enum.sum(memory_values)
      avg = if length(memory_values) > 0, do: total / length(memory_values), else: 0.0
      max = if length(memory_values) > 0, do: Enum.max(memory_values), else: 0.0
      min = if length(memory_values) > 0, do: Enum.min(memory_values), else: 0.0

      memory = %{
        total_memory_mb: Float.round(total, 2),
        avg_memory_per_worker_mb: Float.round(avg, 2),
        max_memory_worker_mb: Float.round(max, 2),
        min_memory_worker_mb: Float.round(min, 2),
        workers: worker_memories
      }

      {:ok, memory}
    end
  end

  @doc """
  Get comprehensive report for all configured pools.

  Returns a map of pool names to their statistics.

  ## Examples

      iex> ProfileInspector.get_comprehensive_report()
      {:ok, %{
        default: %{...},
        hpc_pool: %{...}
      }}
  """
  @spec get_comprehensive_report() :: {:ok, %{pool_name() => pool_stats()}} | {:error, term()}
  def get_comprehensive_report do
    case Config.get_pool_configs() do
      {:ok, configs} ->
        report =
          Enum.reduce(configs, %{}, fn config, acc ->
            pool_name = Map.fetch!(config, :name)

            case get_pool_stats(pool_name) do
              {:ok, stats} -> Map.put(acc, pool_name, stats)
              {:error, _} -> acc
            end
          end)

        {:ok, report}

      error ->
        error
    end
  end

  @doc """
  Check if a pool is approaching capacity saturation.

  Returns a warning if utilization is above the threshold (default 80%).

  ## Examples

      iex> ProfileInspector.check_saturation(:default)
      {:ok, :healthy}

      iex> ProfileInspector.check_saturation(:busy_pool)
      {:warning, :approaching_saturation, 85.5}
  """
  @spec check_saturation(pool_name(), float()) ::
          {:ok, :healthy} | {:warning, :approaching_saturation, float()} | {:error, term()}
  def check_saturation(pool_name \\ :default, threshold \\ 80.0) do
    with {:ok, stats} <- get_pool_stats(pool_name) do
      if stats.utilization_percent >= threshold do
        {:warning, :approaching_saturation, stats.utilization_percent}
      else
        {:ok, :healthy}
      end
    end
  end

  @doc """
  Get recommendations for pool configuration based on current usage.

  Analyzes current pool statistics and provides recommendations for
  optimization.

  ## Examples

      iex> ProfileInspector.get_recommendations(:default)
      {:ok, [
        "Pool utilization is high (85%). Consider adding more workers.",
        "Average memory per worker is 45MB. Monitor for memory leaks."
      ]}
  """
  @spec get_recommendations(pool_name()) :: {:ok, [String.t()]} | {:error, term()}
  def get_recommendations(pool_name \\ :default) do
    with {:ok, pool_stats} <- get_pool_stats(pool_name),
         {:ok, memory_stats} <- get_memory_stats(pool_name) do
      recommendations =
        []
        |> add_utilization_recommendations(pool_stats)
        |> add_memory_recommendations(memory_stats)
        |> add_profile_recommendations(pool_stats)

      {:ok, recommendations}
    end
  end

  # Private functions

  defp get_pool_workers(pool_name) do
    # Try to get workers from the pool
    try do
      workers = Snakepit.Pool.list_workers(pool_name)
      {:ok, workers}
    rescue
      _ -> {:error, :pool_not_found}
    catch
      :exit, _ -> {:error, :pool_not_running}
    end
  end

  defp get_worker_stats(worker_id, profile_module) do
    # Look up worker PID from registry
    case Registry.lookup(Snakepit.Pool.Registry, worker_id) do
      [{pid, _metadata}] ->
        # Get profile-specific information
        {:ok, metadata} = profile_module.get_metadata(worker_id)
        capacity = profile_module.get_capacity(worker_id)
        load = profile_module.get_load(worker_id)

        # Get memory information
        memory_mb = get_worker_memory(pid)

        # Determine status
        status =
          cond do
            load >= capacity -> :busy
            load > 0 -> :busy
            true -> :available
          end

        %{
          worker_id: worker_id,
          pid: pid,
          profile: Map.get(metadata, :profile, :process),
          capacity: capacity,
          load: load,
          memory_mb: memory_mb,
          status: status
        }

      [] ->
        nil
    end
  end

  defp get_worker_memory(pid) when is_pid(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> Float.round(bytes / (1024 * 1024), 2)
      nil -> 0.0
    end
  end

  defp build_thread_info(%{profile: :thread} = stats) do
    # Calculate thread-specific metrics for thread profile pools
    workers_with_threads =
      Enum.filter(stats.workers, fn w -> w.capacity > 1 end)

    if length(workers_with_threads) > 0 do
      total_threads = stats.capacity_total
      workers_count = length(workers_with_threads)

      # Get threads per worker (should be consistent, but take first)
      threads_per_worker =
        case List.first(workers_with_threads) do
          %{capacity: c} -> c
          _ -> 1
        end

      avg_load =
        if workers_count > 0 do
          Enum.sum(Enum.map(workers_with_threads, & &1.load)) / workers_count
        else
          0.0
        end

      %{
        workers: workers_count,
        threads_per_worker: threads_per_worker,
        total_threads: total_threads,
        avg_load_per_worker: Float.round(avg_load, 2)
      }
    else
      nil
    end
  end

  defp build_thread_info(_stats), do: nil

  defp add_utilization_recommendations(recommendations, stats) do
    cond do
      stats.utilization_percent >= 90.0 ->
        [
          "CRITICAL: Pool utilization is very high (#{stats.utilization_percent}%). Add more workers immediately."
          | recommendations
        ]

      stats.utilization_percent >= 80.0 ->
        [
          "WARNING: Pool utilization is high (#{stats.utilization_percent}%). Consider adding more workers."
          | recommendations
        ]

      stats.utilization_percent < 20.0 and stats.worker_count > 10 ->
        [
          "INFO: Pool utilization is low (#{stats.utilization_percent}%). Consider reducing worker count to save resources."
          | recommendations
        ]

      true ->
        recommendations
    end
  end

  defp add_memory_recommendations(recommendations, memory_stats) do
    cond do
      memory_stats.avg_memory_per_worker_mb >= 100.0 ->
        [
          "WARNING: Average memory per worker is high (#{memory_stats.avg_memory_per_worker_mb}MB). Monitor for memory leaks."
          | recommendations
        ]

      memory_stats.max_memory_worker_mb >= 200.0 ->
        [
          "WARNING: Peak worker memory usage is #{memory_stats.max_memory_worker_mb}MB. Consider worker recycling."
          | recommendations
        ]

      true ->
        recommendations
    end
  end

  defp add_profile_recommendations(recommendations, stats) do
    case stats.profile do
      :thread ->
        # Thread-specific recommendations
        if stats.capacity_total > 0 and stats.worker_count > 0 do
          threads_per_worker = div(stats.capacity_total, stats.worker_count)

          cond do
            threads_per_worker < 4 ->
              [
                "INFO: Thread pool has #{threads_per_worker} threads per worker. Consider increasing for better CPU utilization."
                | recommendations
              ]

            threads_per_worker > 32 ->
              [
                "INFO: Thread pool has #{threads_per_worker} threads per worker. Consider reducing to avoid context switching overhead."
                | recommendations
              ]

            true ->
              recommendations
          end
        else
          recommendations
        end

      :process ->
        # Process-specific recommendations
        if stats.worker_count > 200 do
          [
            "INFO: Large number of process workers (#{stats.worker_count}). Consider using thread profile for better resource efficiency."
            | recommendations
          ]
        else
          recommendations
        end
    end
  end
end
