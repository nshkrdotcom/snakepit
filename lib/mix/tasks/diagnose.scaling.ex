defmodule Mix.Tasks.Diagnose.Scaling do
  @moduledoc """
  Comprehensive scaling diagnostics to find the bottleneck preventing >105 workers.

  Usage:
    mix diagnose.scaling
  """

  use Mix.Task
  require Logger

  @shortdoc "Find scaling bottleneck preventing >105 workers"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("🔬 SNAKEPIT SCALING DIAGNOSTICS")
    IO.puts(String.duplicate("=", 80) <> "\n")

    # Run all diagnostics
    check_pool_profiles()
    check_erlang_limits()
    check_erlang_process_limits()
    check_dets_contention()
    check_python_spawn_rate()
    check_grpc_limits()
    find_exact_breaking_point()

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("✅ DIAGNOSTICS COMPLETE")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  defp check_pool_profiles do
    IO.puts("📊 TEST 0: POOL PROFILE ANALYSIS")
    IO.puts(String.duplicate("-", 80))

    case Snakepit.Config.get_pool_configs() do
      {:ok, configs} ->
        IO.puts("Configured pools: #{length(configs)}\n")

        Enum.each(configs, fn config ->
          pool_name = Map.fetch!(config, :name)
          profile = Map.get(config, :worker_profile, :process)
          pool_size = Map.get(config, :pool_size, 0)

          IO.puts("Pool: #{pool_name}")
          IO.puts("  Profile:    #{profile}")
          IO.puts("  Pool Size:  #{pool_size}")

          case profile do
            :thread ->
              threads = Map.get(config, :threads_per_worker, 10)
              total_capacity = pool_size * threads
              IO.puts("  Threads/Worker: #{threads}")
              IO.puts("  Total Capacity: #{total_capacity}")

              # Check if thread profile is appropriate
              if pool_size > 100 do
                IO.puts(
                  "\n⚠️  WARNING: Large pool size (#{pool_size}) with thread profile may not be optimal"
                )

                IO.puts("    Consider: Fewer workers with more threads per worker")
                IO.puts("    Example: 16 workers x 64 threads = 1024 capacity")
              end

            :process ->
              IO.puts("  Capacity:   #{pool_size} (1:1 with workers)")

              if pool_size > 250 do
                IO.puts(
                  "\n⚠️  WARNING: Very large process pool (#{pool_size}). Consider thread profile for better efficiency."
                )

                IO.puts("    Thread profile benefits:")
                IO.puts("      - Lower memory usage (shared interpreter)")
                IO.puts("      - Faster startup (fewer processes)")
                IO.puts("      - Better CPU utilization (Python 3.13+)")
              end
          end

          # Get current pool statistics if available
          case Snakepit.Diagnostics.ProfileInspector.get_pool_stats(pool_name) do
            {:ok, stats} ->
              IO.puts("\nCurrent Status:")
              IO.puts("  Active Workers:  #{stats.worker_count}")
              IO.puts("  Utilization:     #{stats.utilization_percent}%")

              if stats.capacity_available > 0 do
                IO.puts("  Available:       #{stats.capacity_available}")
              end

              # Profile-specific recommendations
              case profile do
                :thread ->
                  if stats.utilization_percent > 80 do
                    IO.puts("\n💡 RECOMMENDATION: High utilization on thread pool")
                    IO.puts("    - Consider increasing threads_per_worker")
                    IO.puts("    - Or add more worker processes")
                  end

                :process ->
                  if stats.utilization_percent > 80 do
                    IO.puts("\n💡 RECOMMENDATION: High utilization on process pool")
                    IO.puts("    - Add more workers (current: #{stats.worker_count})")

                    if stats.worker_count > 100 do
                      IO.puts("    - Or consider switching to thread profile")
                    end
                  end
              end

            {:error, :pool_not_running} ->
              IO.puts("\n⚠️  Pool is not currently running")

            {:error, _} ->
              :ok
          end

          IO.puts("")
        end)

        # Overall system recommendations
        process_pools = Enum.count(configs, fn c -> Map.get(c, :worker_profile) == :process end)
        thread_pools = Enum.count(configs, fn c -> Map.get(c, :worker_profile) == :thread end)
        total_workers = Enum.sum(Enum.map(configs, fn c -> Map.get(c, :pool_size, 0) end))

        IO.puts("System Overview:")
        IO.puts("  Process Pools: #{process_pools}")
        IO.puts("  Thread Pools:  #{thread_pools}")
        IO.puts("  Total Workers: #{total_workers}")

        if total_workers > 300 and thread_pools == 0 do
          IO.puts("\n💡 OPTIMIZATION OPPORTUNITY:")
          IO.puts("    With #{total_workers} workers, consider using thread profile")

          IO.puts(
            "    Example: Replace 300 process workers with 10 thread workers (30 threads each)"
          )

          IO.puts("    Benefits: ~70% memory reduction, faster startup, same throughput")
        end

      {:error, reason} ->
        IO.puts("⚠️  Could not load pool configurations: #{inspect(reason)}")
    end

    IO.puts("\n")
  end

  defp check_erlang_limits do
    IO.puts("📊 TEST 1: ERLANG PORT LIMITS")
    IO.puts(String.duplicate("-", 80))

    port_limit = :erlang.system_info(:port_limit)
    port_count = :erlang.system_info(:port_count)
    port_available = port_limit - port_count

    IO.puts("Port Limit:     #{format_number(port_limit)}")
    IO.puts("Current Ports:  #{format_number(port_count)}")
    IO.puts("Available:      #{format_number(port_available)}")
    IO.puts("Usage:          #{Float.round(port_count / port_limit * 100, 2)}%")

    # Estimate ports per worker
    if port_count > 0 do
      # Try to count actual workers
      worker_count = count_workers()

      if worker_count > 0 do
        ports_per_worker = port_count / worker_count
        IO.puts("\nEstimated ports per worker: #{Float.round(ports_per_worker, 2)}")
        max_workers = floor(port_limit / ports_per_worker)
        IO.puts("Theoretical max workers: #{max_workers}")

        if max_workers < 110 do
          IO.puts("\n⚠️  WARNING: Port limit would prevent 110 workers!")

          IO.puts(
            "    At #{Float.round(ports_per_worker, 2)} ports/worker, you can only spawn ~#{max_workers} workers"
          )
        end
      end
    end

    # Check if we're close to the limit
    if port_available < 1000 do
      IO.puts("\n🔴 CRITICAL: Less than 1000 ports available!")
    else
      if port_count / port_limit > 0.8 do
        IO.puts("\n⚠️  WARNING: Using >80% of port limit")
      else
        IO.puts("\n✅ Port usage looks healthy")
      end
    end

    IO.puts("\n")
  end

  defp check_erlang_process_limits do
    IO.puts("📊 TEST 2: ERLANG PROCESS LIMITS")
    IO.puts(String.duplicate("-", 80))

    process_limit = :erlang.system_info(:process_limit)
    process_count = :erlang.system_info(:process_count)
    process_available = process_limit - process_count

    IO.puts("Process Limit:  #{format_number(process_limit)}")
    IO.puts("Current Procs:  #{format_number(process_count)}")
    IO.puts("Available:      #{format_number(process_available)}")
    IO.puts("Usage:          #{Float.round(process_count / process_limit * 100, 2)}%")

    # Count snakepit-related processes
    snakepit_procs =
      Process.list()
      |> Enum.count(fn pid ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} ->
            name_str = to_string(name)
            String.contains?(name_str, "snakepit") || String.contains?(name_str, "Snakepit")

          _ ->
            # Check initial call
            case Process.info(pid, :initial_call) do
              {:initial_call, {mod, _fun, _arity}} ->
                mod_str = to_string(mod)
                String.contains?(mod_str, "Snakepit")

              _ ->
                false
            end
        end
      end)

    IO.puts("\nSnakepit processes: #{snakepit_procs}")

    worker_count = count_workers()

    if worker_count > 0 do
      procs_per_worker = process_count / worker_count
      IO.puts("Estimated procs per worker: #{Float.round(procs_per_worker, 2)}")
      max_workers = floor(process_limit / procs_per_worker)
      IO.puts("Theoretical max workers: #{max_workers}")

      if max_workers < 110 do
        IO.puts("\n⚠️  WARNING: Process limit would prevent 110 workers!")
      end
    end

    if process_count / process_limit > 0.8 do
      IO.puts("\n⚠️  WARNING: Using >80% of process limit")
    else
      IO.puts("\n✅ Process usage looks healthy")
    end

    IO.puts("\n")
  end

  defp check_dets_contention do
    IO.puts("📊 TEST 3: DETS LOCK CONTENTION")
    IO.puts(String.duplicate("-", 80))

    case Process.whereis(Snakepit.Pool.ProcessRegistry) do
      nil ->
        IO.puts("⚠️  ProcessRegistry is not running. Skipping DETS diagnostics.")

      _pid ->
        case Snakepit.Pool.ProcessRegistry.dets_table_size() do
          {:ok, size} ->
            IO.puts("DETS table size: #{size} entries")

          {:error, :not_initialized} ->
            IO.puts("⚠️  DETS table not initialized yet")

          {:error, reason} ->
            IO.puts("⚠️  Could not query DETS table: #{inspect(reason)}")
        end

        IO.puts("\nTesting registry write throughput (110 concurrent operations)...")

        {time_us, outcomes} =
          :timer.tc(fn ->
            1..110
            |> Task.async_stream(&stress_process_registry/1,
              max_concurrency: 110,
              timeout: 30_000
            )
            |> Enum.map(fn
              {:ok, {:ok, elapsed}} -> {:ok, elapsed}
              {:ok, {:error, reason, elapsed}} -> {:error, reason, elapsed}
              {:exit, reason} -> {:error, reason, 0}
            end)
          end)

        total_time_s = time_us / 1_000_000

        success_times =
          for {:ok, elapsed} <- outcomes do
            elapsed
          end

        failure_reasons =
          for {:error, reason, _elapsed} <- outcomes do
            reason
          end

        successes = length(success_times)
        failures = length(failure_reasons)

        IO.puts("\nResults:")
        IO.puts("  Total time:     #{Float.round(total_time_s, 3)}s")
        IO.puts("  Successes:      #{successes}/110")
        IO.puts("  Failures:       #{failures}/110")

        if success_times != [] do
          avg_write_us = Enum.sum(success_times) / length(success_times)
          max_write_us = Enum.max(success_times)
          min_write_us = Enum.min(success_times)

          IO.puts("  Avg cycle time: #{Float.round(avg_write_us / 1000, 2)}ms")
          IO.puts("  Min cycle time: #{Float.round(min_write_us / 1000, 2)}ms")
          IO.puts("  Max cycle time: #{Float.round(max_write_us / 1000, 2)}ms")

          cond do
            total_time_s > 5.0 ->
              IO.puts("\n🔴 CRITICAL: Registry writes are extremely slow!")
              IO.puts("    110 reserve/activate cycles took #{Float.round(total_time_s, 1)}s")
              IO.puts("    Investigate DETS serialization and worker startup congestion.")

            total_time_s > 2.0 ->
              IO.puts("\n⚠️  WARNING: Registry writes are slow (#{Float.round(total_time_s, 1)}s)")
              IO.puts("    This could contribute to timeouts during worker startup.")

            true ->
              IO.puts("\n✅ Registry throughput looks acceptable.")
          end
        end

        if failure_reasons != [] do
          sample_reason = hd(failure_reasons)
          IO.puts("\n⚠️  Failures detected: #{failures}")
          IO.puts("    Example failure: #{inspect(sample_reason)}")
        end
    end

    IO.puts("\n")
  end

  defp check_python_spawn_rate do
    IO.puts("📊 TEST 4: PYTHON PROCESS SPAWN RATE")
    IO.puts(String.duplicate("-", 80))

    IO.puts("Testing Python process spawn rate (110 processes)...")

    case python_executable() do
      nil ->
        IO.puts("⚠️  python3/python executable not found on PATH. Skipping test.\n")

      python ->
        spawn_fun = fn ->
          case System.cmd(python, ["-c", "import sys; sys.exit(0)"], stderr_to_stdout: true) do
            {_output, 0} ->
              :ok

            {output, code} ->
              {:error, {:exit_status, code, String.trim(output)}}
          end
        end

        case measure_python_spawn(110, spawn_fun) do
          {:ok, %{duration_us: duration_us, results: results}} ->
            time_s = duration_us / 1_000_000
            successes = Enum.count(results, &(&1 == :ok))
            failures = Enum.reject(results, &(&1 == :ok))

            IO.puts("Time to spawn 110 Python processes: #{Float.round(time_s, 2)}s")
            IO.puts("Successes: #{successes}")
            IO.puts("Failures:  #{length(failures)}")

            if failures != [] do
              sample_failure = hd(failures)
              IO.puts("Sample failure: #{inspect(sample_failure)}")
            end

            cond do
              time_s > 30.0 ->
                IO.puts("\n🔴 CRITICAL: Python spawn rate is very slow!")
                IO.puts("    System may be CPU or fork() constrained.")

              time_s > 10.0 ->
                IO.puts("\n⚠️  WARNING: Python spawn rate is slow (#{Float.round(time_s, 1)}s)")

              true ->
                IO.puts("\n✅ Python spawn rate looks good (#{Float.round(time_s, 2)}s)")
            end

          {:error, reason} ->
            IO.puts("⚠️  Failed to measure Python spawn rate: #{inspect(reason)}")
        end
    end

    IO.puts("\n")
  end

  defp check_grpc_limits do
    IO.puts("📊 TEST 5: GRPC CONNECTION LIMITS")
    IO.puts(String.duplicate("-", 80))

    # Check for Ranch (used by GRPC.Server)
    try do
      ranch_info = :ranch.info()
      IO.puts("Ranch info:")
      IO.inspect(ranch_info, limit: :infinity, pretty: true)
    rescue
      _ ->
        IO.puts("Ranch not available or not running")
    end

    # Count TCP connections
    case fetch_ss_lines(["-tan"]) do
      {:ok, lines} ->
        tcp_count = count_established_from_lines(lines)
        IO.puts("\nEstablished TCP connections: #{tcp_count}")

        worker_count = count_workers()

        if worker_count > 0 do
          tcp_per_worker = tcp_count / worker_count
          IO.puts("TCP connections per worker: #{Float.round(tcp_per_worker, 2)}")
        end

      {:error, reason} ->
        IO.puts("\n⚠️  Unable to count TCP connections: #{format_ss_error(reason)}")
    end

    # Check gRPC port status
    case fetch_ss_lines(["-tlnp"]) do
      {:ok, lines} ->
        ports = filter_listener_lines(lines, [50051, 50052])

        if ports == [] do
          IO.puts("\ngRPC ports not currently listening (50051/50052)")
        else
          IO.puts("\ngRPC port status:")
          Enum.each(ports, &IO.puts/1)
        end

      {:error, reason} ->
        IO.puts("\n⚠️  Unable to inspect gRPC ports: #{format_ss_error(reason)}")
    end

    IO.puts("\n")
  end

  defp find_exact_breaking_point do
    IO.puts("📊 TEST 6: BINARY SEARCH FOR EXACT BREAKING POINT")
    IO.puts(String.duplicate("-", 80))
    IO.puts("\n⚠️  This test spawns real workers and may fail!")
    IO.puts("Testing from 100 to 400 workers in increments...\n")

    # Capture baseline metrics
    baseline = capture_metrics()
    IO.puts("Baseline metrics:")
    print_metrics(baseline)

    # Test increasing worker counts
    results =
      for count <- [100, 250, 400, 500] do
        IO.puts("\n" <> String.duplicate("-", 60))
        IO.puts("🔬 Testing #{count} workers...")

        # Small delay between tests
        :timer.sleep(2000)

        before_metrics = capture_metrics()

        # Try to start a worker
        worker_id = "diagnostic_#{count}_#{:rand.uniform(999_999)}"

        start_time = System.monotonic_time(:millisecond)

        result =
          try do
            # Check if WorkerSupervisor exists
            case Process.whereis(Snakepit.Pool.WorkerSupervisor) do
              nil ->
                {:error, :supervisor_not_running}

              _pid ->
                Snakepit.Pool.WorkerSupervisor.start_worker(
                  worker_id,
                  Snakepit.GRPCWorker,
                  Snakepit.Adapters.GRPCPython,
                  Snakepit.Pool
                )
            end
          rescue
            e -> {:error, e}
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        elapsed = System.monotonic_time(:millisecond) - start_time

        after_metrics = capture_metrics()
        delta = calculate_delta(before_metrics, after_metrics)

        status =
          case result do
            {:ok, _pid} -> :success
            {:error, reason} -> {:failed, reason}
          end

        # Clean up if successful
        if status == :success do
          try do
            Snakepit.Pool.WorkerSupervisor.stop_worker(worker_id)
          rescue
            _ -> :ok
          end
        end

        result_data = %{
          count: count,
          status: status,
          elapsed_ms: elapsed,
          before: before_metrics,
          after: after_metrics,
          delta: delta
        }

        print_test_result(result_data)

        result_data
      end

    # Analyze results
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("📈 ANALYSIS")
    IO.puts(String.duplicate("=", 60))

    first_failure =
      Enum.find(results, fn r ->
        match?({:failed, _}, r.status)
      end)

    case first_failure do
      nil ->
        IO.puts("\n✅ All tests passed up to 500 workers!")
        IO.puts("   The bottleneck may be higher than 500.")

      %{count: count, status: {:failed, reason}} ->
        IO.puts("\n🔴 FIRST FAILURE AT #{count} WORKERS")
        IO.puts("\nReason: #{inspect(reason, pretty: true)}")

        # Check what metric grew most
        analyze_metric_growth(results, count)
    end

    IO.puts("\n")
  end

  defp capture_metrics do
    %{
      erlang_ports: :erlang.system_info(:port_count),
      erlang_procs: :erlang.system_info(:process_count),
      tcp_connections: count_tcp_connections(),
      worker_count: count_workers(),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp calculate_delta(before, after_metrics) do
    %{
      ports: after_metrics.erlang_ports - before.erlang_ports,
      procs: after_metrics.erlang_procs - before.erlang_procs,
      tcp: after_metrics.tcp_connections - before.tcp_connections,
      workers: after_metrics.worker_count - before.worker_count,
      memory_mb: (after_metrics.memory_bytes - before.memory_bytes) / (1024 * 1024)
    }
  end

  defp print_metrics(metrics) do
    IO.puts("  Erlang ports: #{metrics.erlang_ports}")
    IO.puts("  Erlang procs: #{metrics.erlang_procs}")
    IO.puts("  TCP conns:    #{metrics.tcp_connections}")
    IO.puts("  Workers:      #{metrics.worker_count}")
    IO.puts("  Memory:       #{Float.round(metrics.memory_bytes / (1024 * 1024), 1)} MB")
  end

  defp print_test_result(result) do
    case result.status do
      :success ->
        IO.puts("✅ SUCCESS (#{result.elapsed_ms}ms)")

      {:failed, reason} ->
        IO.puts("🔴 FAILED (#{result.elapsed_ms}ms)")
        IO.puts("   Reason: #{inspect(reason)}")
    end

    IO.puts("\nMetric deltas:")
    IO.puts("  Ports:   #{format_delta(result.delta.ports)}")
    IO.puts("  Procs:   #{format_delta(result.delta.procs)}")
    IO.puts("  TCP:     #{format_delta(result.delta.tcp)}")
    IO.puts("  Workers: #{format_delta(result.delta.workers)}")
    IO.puts("  Memory:  #{format_delta(result.delta.memory_mb)} MB")
  end

  defp analyze_metric_growth(results, failure_count) do
    successful = Enum.filter(results, fn r -> r.status == :success end)

    if length(successful) > 0 do
      # Calculate average resource usage per worker from successful runs
      avg_delta = %{
        ports: avg(Enum.map(successful, & &1.delta.ports)),
        procs: avg(Enum.map(successful, & &1.delta.procs)),
        tcp: avg(Enum.map(successful, & &1.delta.tcp))
      }

      IO.puts("\nAverage resource usage per worker (from successful runs):")
      IO.puts("  Ports per worker:  #{Float.round(avg_delta.ports, 2)}")
      IO.puts("  Procs per worker:  #{Float.round(avg_delta.procs, 2)}")
      IO.puts("  TCP per worker:    #{Float.round(avg_delta.tcp, 2)}")

      # Extrapolate to limits
      port_limit = :erlang.system_info(:port_limit)
      proc_limit = :erlang.system_info(:process_limit)

      max_by_ports = floor(port_limit / avg_delta.ports)
      max_by_procs = floor(proc_limit / avg_delta.procs)

      IO.puts("\n📊 PROJECTED MAXIMUMS:")
      IO.puts("  Max by ports:      #{max_by_ports} workers")
      IO.puts("  Max by processes:  #{max_by_procs} workers")

      bottleneck =
        cond do
          max_by_ports < failure_count ->
            IO.puts("\n🔴 SMOKING GUN: ERLANG PORT LIMIT")

            IO.puts(
              "    At #{Float.round(avg_delta.ports, 2)} ports/worker, you hit the #{port_limit} port limit at ~#{max_by_ports} workers"
            )

            :ports

          max_by_procs < failure_count ->
            IO.puts("\n🔴 SMOKING GUN: ERLANG PROCESS LIMIT")

            IO.puts(
              "    At #{Float.round(avg_delta.procs, 2)} procs/worker, you hit the #{proc_limit} process limit at ~#{max_by_procs} workers"
            )

            :procs

          true ->
            IO.puts("\n🤔 UNCLEAR: Neither port nor process limit explains the failure")
            IO.puts("    Check the error message above for clues")
            :unknown
        end

      # Suggest solutions
      suggest_solutions(bottleneck, avg_delta)
    end
  end

  defp suggest_solutions(:ports, avg_delta) do
    IO.puts("\n💡 SOLUTIONS:")
    IO.puts("  1. Increase Erlang port limit in vm.args:")
    IO.puts("     +Q 1000000")
    IO.puts("  2. Each worker uses #{Float.round(avg_delta.ports, 1)} ports - investigate why:")
    IO.puts("     - 1 Port for stdin/stdout")
    IO.puts("     - 1 TCP socket for gRPC")
    IO.puts("     - Additional ports for...?")
    IO.puts("  3. Consider reducing port usage per worker")
  end

  defp suggest_solutions(:procs, avg_delta) do
    IO.puts("\n💡 SOLUTIONS:")
    IO.puts("  1. Increase Erlang process limit in vm.args:")
    IO.puts("     +P 5000000")

    IO.puts(
      "  2. Each worker uses #{Float.round(avg_delta.procs, 1)} processes - investigate supervision tree depth"
    )

    IO.puts("  3. Consider flattening the supervision tree")
  end

  defp suggest_solutions(:unknown, _avg_delta) do
    IO.puts("\n💡 NEXT STEPS:")
    IO.puts("  1. Check the error message for clues")
    IO.puts("  2. Look for timeouts in worker startup")
    IO.puts("  3. Check DETS test results above")
    IO.puts("  4. Monitor system resources (CPU, memory, file descriptors)")
  end

  defp stress_process_registry(index) do
    worker_id = "diagnostic_worker_#{index}_#{System.unique_integer([:positive])}"
    start = System.monotonic_time(:microsecond)

    result =
      try do
        case Snakepit.Pool.ProcessRegistry.reserve_worker(worker_id) do
          :ok ->
            activation =
              Snakepit.Pool.ProcessRegistry.activate_worker(
                worker_id,
                self(),
                0,
                %{diagnostic: true}
              )

            case activation do
              :ok ->
                Snakepit.Pool.ProcessRegistry.unregister_worker(worker_id)
                :ok

              {:error, reason} ->
                Snakepit.Pool.ProcessRegistry.unregister_worker(worker_id)
                {:error, {:activate_failed, reason}}

              other ->
                Snakepit.Pool.ProcessRegistry.unregister_worker(worker_id)
                {:error, {:activate_failed, other}}
            end

          {:error, _reason} = error ->
            error
        end
      rescue
        error -> {:error, {:exception, error}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    elapsed = System.monotonic_time(:microsecond) - start

    case result do
      :ok -> {:ok, elapsed}
      {:error, reason} -> {:error, reason, elapsed}
      other -> {:error, other, elapsed}
    end
  end

  @doc false
  def python_executable do
    System.find_executable("python3") || System.find_executable("python")
  end

  @doc false
  def measure_python_spawn(count, spawn_fun)
      when is_integer(count) and count > 0 and is_function(spawn_fun, 0) do
    {duration_us, results} =
      :timer.tc(fn ->
        1..count
        |> Task.async_stream(fn _ -> spawn_fun.() end, max_concurrency: count, timeout: 30_000)
        |> Enum.map(fn
          {:ok, :ok} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:exit, reason} -> {:error, reason}
          other -> {:error, other}
        end)
      end)

    {:ok, %{duration_us: duration_us, results: results}}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc false
  def fetch_ss_lines(args) when is_list(args) do
    ss_path = System.find_executable("ss")

    cond do
      not match?({:unix, _}, :os.type()) ->
        {:error, :unsupported_os}

      is_nil(ss_path) ->
        {:error, :ss_not_found}

      true ->
        case System.cmd(ss_path, args, stderr_to_stdout: true) do
          {output, 0} ->
            lines =
              output
              |> String.split("\n", trim: true)
              |> Enum.reject(&(&1 == ""))

            {:ok, lines}

          {output, code} ->
            {:error, {:ss_failed, code, String.trim(output)}}
        end
    end
  end

  @doc false
  def count_established_from_lines(lines) when is_list(lines) do
    lines
    |> Enum.reject(&header_line?/1)
    |> Enum.count(fn line -> String.contains?(line, "ESTAB") end)
  end

  defp header_line?(line) do
    String.starts_with?(String.trim_leading(line), "Netid")
  end

  @doc false
  def filter_listener_lines(lines, ports) when is_list(lines) and is_list(ports) do
    Enum.filter(lines, fn line ->
      Enum.any?(ports, fn port -> String.contains?(line, ":#{port}") end)
    end)
  end

  defp format_ss_error(:unsupported_os) do
    os = :os.type() |> inspect()
    "ss command not supported on #{os}"
  end

  defp format_ss_error(:ss_not_found), do: "ss command not available (install iproute2 package)"

  defp format_ss_error({:ss_failed, code, output}) do
    snippet = String.slice(output || "", 0, 200)
    "ss exited with #{code}: #{snippet}"
  end

  defp format_ss_error(reason), do: inspect(reason)

  defp count_workers do
    try do
      case Process.whereis(Snakepit.Pool.Registry) do
        nil ->
          0

        _pid ->
          Registry.count(Snakepit.Pool.Registry)
      end
    rescue
      _ -> 0
    end
  end

  defp count_tcp_connections do
    case fetch_ss_lines(["-tan"]) do
      {:ok, lines} -> count_established_from_lines(lines)
      {:error, _reason} -> 0
    end
  end

  defp avg(list) when length(list) > 0 do
    Enum.sum(list) / length(list)
  end

  defp avg(_), do: 0.0

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 2)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_number(num), do: to_string(num)

  defp format_delta(num) when num >= 0, do: "+#{Float.round(num * 1.0, 2)}"
  defp format_delta(num), do: Float.round(num * 1.0, 2) |> to_string()
end
