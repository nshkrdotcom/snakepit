defmodule Mix.Tasks.Snakepit.ProfileInspector do
  @moduledoc """
  Inspect Snakepit pool profiles and worker statistics.

  This task provides detailed information about pool configurations,
  worker profiles (process vs thread), capacity utilization, memory usage,
  and performance recommendations.

  ## Usage

      # Inspect all pools
      mix snakepit.profile_inspector

      # Inspect a specific pool
      mix snakepit.profile_inspector --pool default

      # Show detailed per-worker information
      mix snakepit.profile_inspector --detailed

      # Export to JSON format
      mix snakepit.profile_inspector --format json

  ## Options

    * `--pool` - Specific pool to inspect (default: all pools)
    * `--detailed` - Show detailed per-worker statistics
    * `--format` - Output format: text (default) or json
    * `--recommendations` - Show optimization recommendations

  ## Examples

      # Basic inspection
      mix snakepit.profile_inspector

      # Detailed inspection of HPC pool
      mix snakepit.profile_inspector --pool hpc --detailed

      # Get recommendations
      mix snakepit.profile_inspector --recommendations
  """

  use Mix.Task
  require Logger

  alias Snakepit.Diagnostics.ProfileInspector
  alias Snakepit.Config

  @shortdoc "Inspect pool profiles and worker statistics"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          pool: :string,
          detailed: :boolean,
          format: :string,
          recommendations: :boolean
        ]
      )

    # Start the application
    Mix.Task.run("app.start")

    format = Keyword.get(opts, :format, "text")
    pool_name = parse_pool_name(Keyword.get(opts, :pool))
    detailed? = Keyword.get(opts, :detailed, false)
    show_recommendations? = Keyword.get(opts, :recommendations, false)

    case format do
      "json" ->
        run_json_format(pool_name)

      "text" ->
        run_text_format(pool_name, detailed?, show_recommendations?)

      invalid ->
        IO.puts("Error: Invalid format '#{invalid}'. Use 'text' or 'json'.")
        System.halt(1)
    end
  end

  # Private functions

  defp parse_pool_name(nil), do: nil

  defp parse_pool_name(name) when is_binary(name) do
    String.to_atom(name)
  end

  defp run_text_format(nil, detailed?, show_recommendations?) do
    # Inspect all pools
    print_header()

    case Config.get_pool_configs() do
      {:ok, configs} ->
        Enum.each(configs, fn config ->
          pool_name = Map.fetch!(config, :name)
          inspect_pool_text(pool_name, config, detailed?)

          if show_recommendations? do
            print_recommendations(pool_name)
          end
        end)

      {:error, reason} ->
        IO.puts("\n❌ Error: Failed to get pool configurations: #{inspect(reason)}")
        System.halt(1)
    end

    print_footer()
  end

  defp run_text_format(pool_name, detailed?, show_recommendations?) do
    print_header()

    case Config.get_pool_config(pool_name) do
      {:ok, config} ->
        inspect_pool_text(pool_name, config, detailed?)

        if show_recommendations? do
          print_recommendations(pool_name)
        end

      {:error, :pool_not_found} ->
        IO.puts("\n❌ Error: Pool '#{pool_name}' not found")
        System.halt(1)

      {:error, reason} ->
        IO.puts("\n❌ Error: #{inspect(reason)}")
        System.halt(1)
    end

    print_footer()
  end

  defp run_json_format(nil) do
    # Export all pools as JSON
    case ProfileInspector.get_comprehensive_report() do
      {:ok, report} ->
        json = Jason.encode!(report, pretty: true)
        IO.puts(json)

      {:error, reason} ->
        error = %{error: inspect(reason)}
        json = Jason.encode!(error, pretty: true)
        IO.puts(json)
        System.halt(1)
    end
  end

  defp run_json_format(pool_name) do
    # Export specific pool as JSON
    case ProfileInspector.get_pool_stats(pool_name) do
      {:ok, stats} ->
        json = Jason.encode!(stats, pretty: true)
        IO.puts(json)

      {:error, reason} ->
        error = %{error: inspect(reason)}
        json = Jason.encode!(error, pretty: true)
        IO.puts(json)
        System.halt(1)
    end
  end

  defp print_header do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("🔍 SNAKEPIT PROFILE INSPECTOR")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  defp print_footer do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("✅ INSPECTION COMPLETE")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  defp inspect_pool_text(pool_name, config, detailed?) do
    IO.puts("📊 Pool: #{pool_name}")
    IO.puts(String.duplicate("-", 80))

    # Show configuration
    print_configuration(config)

    # Get and display statistics
    case ProfileInspector.get_pool_stats(pool_name) do
      {:ok, stats} ->
        print_statistics(stats)
        print_capacity_info(stats)
        print_memory_info(pool_name)

        if detailed? do
          print_worker_details(stats.workers)
        end

      {:error, :pool_not_running} ->
        IO.puts("⚠️  Pool is not currently running")

      {:error, reason} ->
        IO.puts("❌ Error getting pool stats: #{inspect(reason)}")
    end

    IO.puts("")
  end

  defp print_configuration(config) do
    IO.puts("\n📋 Configuration:")
    profile = Map.get(config, :worker_profile, :process)
    pool_size = Map.get(config, :pool_size, 0)

    IO.puts("  Profile:          #{format_profile(profile)}")
    IO.puts("  Pool Size:        #{pool_size}")

    case profile do
      :thread ->
        threads = Map.get(config, :threads_per_worker, 10)
        total_capacity = pool_size * threads
        IO.puts("  Threads/Worker:   #{threads}")
        IO.puts("  Total Capacity:   #{total_capacity}")

        if Map.get(config, :thread_safety_checks, false) do
          IO.puts("  Safety Checks:    ✓ Enabled")
        end

      :process ->
        IO.puts("  Workers/Capacity: 1:1 (single-threaded)")

        batch_size = Map.get(config, :startup_batch_size, 8)
        IO.puts("  Batch Size:       #{batch_size}")
    end

    # Lifecycle settings
    case Map.get(config, :worker_ttl, :infinity) do
      :infinity -> :ok
      {value, unit} -> IO.puts("  Worker TTL:       #{value} #{unit}")
    end

    case Map.get(config, :worker_max_requests, :infinity) do
      :infinity -> :ok
      count -> IO.puts("  Max Requests:     #{count}")
    end
  end

  defp print_statistics(stats) do
    IO.puts("\n📈 Statistics:")
    IO.puts("  Active Workers:   #{stats.worker_count}")
    IO.puts("  Total Capacity:   #{stats.capacity_total}")
    IO.puts("  Used Capacity:    #{stats.capacity_used}")
    IO.puts("  Available:        #{stats.capacity_available}")

    # Color-coded utilization
    utilization_str = format_utilization(stats.utilization_percent)
    IO.puts("  Utilization:      #{utilization_str}")
  end

  defp print_capacity_info(stats) do
    case stats.profile do
      :thread ->
        if stats.capacity_total > 0 and stats.worker_count > 0 do
          threads_per_worker = div(stats.capacity_total, stats.worker_count)
          avg_load = div(stats.capacity_used, max(stats.worker_count, 1))

          IO.puts("\n🧵 Thread Profile Details:")
          IO.puts("  Workers:          #{stats.worker_count} processes")
          IO.puts("  Threads/Worker:   #{threads_per_worker}")
          IO.puts("  Total Threads:    #{stats.capacity_total}")
          IO.puts("  Avg Load/Worker:  #{avg_load}/#{threads_per_worker} threads")
        end

      :process ->
        IO.puts("\n⚙️  Process Profile Details:")
        IO.puts("  Mode:             Single-threaded processes")
        IO.puts("  Isolation:        Full process isolation")
        IO.puts("  Concurrency:      #{stats.capacity_total} concurrent requests")
    end
  end

  defp print_memory_info(pool_name) do
    case ProfileInspector.get_memory_stats(pool_name) do
      {:ok, memory} ->
        IO.puts("\n💾 Memory Usage:")
        IO.puts("  Total:            #{memory.total_memory_mb} MB")
        IO.puts("  Average/Worker:   #{memory.avg_memory_per_worker_mb} MB")
        IO.puts("  Max Worker:       #{memory.max_memory_worker_mb} MB")
        IO.puts("  Min Worker:       #{memory.min_memory_worker_mb} MB")

      {:error, _} ->
        :ok
    end
  end

  defp print_worker_details(workers) do
    IO.puts("\n👷 Worker Details:")
    IO.puts(String.duplicate("-", 80))

    IO.puts(
      String.pad_trailing("Worker ID", 30) <>
        String.pad_trailing("Status", 12) <>
        String.pad_trailing("Load/Cap", 12) <>
        String.pad_trailing("Memory", 12) <>
        "PID"
    )

    IO.puts(String.duplicate("-", 80))

    Enum.each(workers, fn worker ->
      worker_id_short = String.slice(worker.worker_id, 0, 28)
      status = format_worker_status(worker.status)
      load_cap = "#{worker.load}/#{worker.capacity}"
      memory = "#{worker.memory_mb} MB"
      pid = inspect(worker.pid)

      IO.puts(
        String.pad_trailing(worker_id_short, 30) <>
          String.pad_trailing(status, 12) <>
          String.pad_trailing(load_cap, 12) <>
          String.pad_trailing(memory, 12) <>
          pid
      )
    end)
  end

  defp print_recommendations(pool_name) do
    case ProfileInspector.get_recommendations(pool_name) do
      {:ok, [_ | _] = recommendations} ->
        IO.puts("\n💡 Recommendations:")

        Enum.each(recommendations, fn rec ->
          IO.puts("  • #{rec}")
        end)

      {:ok, []} ->
        IO.puts("\n✅ No recommendations - pool is operating optimally")

      {:error, _} ->
        :ok
    end
  end

  # Formatting helpers

  defp format_profile(:process), do: "Process (multi-process)"
  defp format_profile(:thread), do: "Thread (multi-threaded)"
  defp format_profile(other), do: to_string(other)

  defp format_utilization(percent) when percent >= 90.0 do
    "#{percent}% 🔴 CRITICAL"
  end

  defp format_utilization(percent) when percent >= 80.0 do
    "#{percent}% 🟡 HIGH"
  end

  defp format_utilization(percent) when percent >= 60.0 do
    "#{percent}% 🟢 GOOD"
  end

  defp format_utilization(percent) do
    "#{percent}% ⚪ LOW"
  end

  defp format_worker_status(:available), do: "✓ Available"
  defp format_worker_status(:busy), do: "● Busy"
  defp format_worker_status(:unknown), do: "? Unknown"
end
