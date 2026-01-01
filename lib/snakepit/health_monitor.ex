defmodule Snakepit.HealthMonitor do
  @moduledoc """
  Monitors worker health and crash patterns.

  Tracks crashes within a rolling window and determines overall pool health.
  Can be used to trigger circuit breaker actions or alerting.

  ## Usage

      {:ok, hm} = HealthMonitor.start_link(
        name: :my_pool_health,
        pool: :default,
        max_crashes: 10,
        crash_window_ms: 60_000
      )

      HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})

      if HealthMonitor.healthy?(hm) do
        # Pool is healthy
      else
        # Too many crashes, consider action
      end
  """

  use GenServer

  alias Snakepit.Defaults
  require Logger

  @type worker_stats :: %{
          crash_count: non_neg_integer(),
          last_crash_time: integer() | nil,
          crash_reasons: [term()]
        }

  @type t :: %{
          pool: atom(),
          workers: %{String.t() => worker_stats()},
          crash_window_ms: pos_integer(),
          max_crashes: pos_integer(),
          total_crashes: non_neg_integer(),
          check_interval_ms: pos_integer(),
          check_timer: reference() | nil
        }

  # Client API

  @doc """
  Starts a health monitor.

  ## Options

  - `:name` - GenServer name (required)
  - `:pool` - Pool name to monitor (required)
  - `:check_interval_ms` - Health check interval (default: 30000)
  - `:crash_window_ms` - Rolling window for crash counting (default: 60000)
  - `:max_crashes` - Max crashes in window before unhealthy (default: 10)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a worker crash.
  """
  @spec record_crash(GenServer.server(), String.t(), map()) :: :ok
  def record_crash(server, worker_id, info \\ %{}) do
    GenServer.cast(server, {:record_crash, worker_id, info})
  end

  @doc """
  Returns whether the pool is considered healthy.
  """
  @spec healthy?(GenServer.server()) :: boolean()
  def healthy?(server) do
    GenServer.call(server, :healthy?)
  end

  @doc """
  Returns health status for a specific worker.
  """
  @spec worker_health(GenServer.server(), String.t()) :: map()
  def worker_health(server, worker_id) do
    GenServer.call(server, {:worker_health, worker_id})
  end

  @doc """
  Returns comprehensive health statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :get_stats)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    pool = Keyword.fetch!(opts, :pool)

    state = %{
      pool: pool,
      workers: %{},
      crash_window_ms:
        Keyword.get(opts, :crash_window_ms, Defaults.health_monitor_crash_window_ms()),
      max_crashes: Keyword.get(opts, :max_crashes, Defaults.health_monitor_max_crashes()),
      total_crashes: 0,
      check_interval_ms:
        Keyword.get(opts, :check_interval_ms, Defaults.health_monitor_check_interval()),
      check_timer: nil
    }

    # Schedule periodic cleanup
    timer = schedule_cleanup(state.check_interval_ms)

    {:ok, %{state | check_timer: timer}}
  end

  @impl true
  def handle_call(:healthy?, _from, state) do
    crashes_in_window = count_crashes_in_window(state)
    healthy = crashes_in_window < state.max_crashes

    {:reply, healthy, state}
  end

  def handle_call({:worker_health, worker_id}, _from, state) do
    worker_stats = Map.get(state.workers, worker_id, default_worker_stats())

    health = %{
      healthy: worker_stats.crash_count < 3,
      crash_count: worker_stats.crash_count,
      last_crash_time: worker_stats.last_crash_time
    }

    {:reply, health, state}
  end

  def handle_call(:get_stats, _from, state) do
    crashes_in_window = count_crashes_in_window(state)

    stats = %{
      pool: state.pool,
      total_crashes: state.total_crashes,
      crashes_in_window: crashes_in_window,
      workers_with_crashes: map_size(state.workers),
      max_crashes: state.max_crashes,
      crash_window_ms: state.crash_window_ms,
      is_healthy: crashes_in_window < state.max_crashes
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:record_crash, worker_id, info}, state) do
    now = System.monotonic_time(:millisecond)

    worker_stats =
      state.workers
      |> Map.get(worker_id, default_worker_stats())
      |> update_worker_crash(info, now)

    workers = Map.put(state.workers, worker_id, worker_stats)

    state = %{
      state
      | workers: workers,
        total_crashes: state.total_crashes + 1
    }

    # Emit telemetry
    :telemetry.execute(
      [:snakepit, :worker, :crash],
      %{},
      %{
        pool: state.pool,
        worker_id: worker_id,
        reason: Map.get(info, :reason)
      }
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove old crash data
    state = cleanup_old_crashes(state)

    # Reschedule
    timer = schedule_cleanup(state.check_interval_ms)

    {:noreply, %{state | check_timer: timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end

  defp default_worker_stats do
    %{
      crash_count: 0,
      last_crash_time: nil,
      crash_reasons: [],
      crash_times: []
    }
  end

  defp update_worker_crash(stats, info, now) do
    reason = Map.get(info, :reason)

    %{
      stats
      | crash_count: stats.crash_count + 1,
        last_crash_time: now,
        crash_reasons: [reason | Enum.take(stats.crash_reasons, 9)],
        crash_times: [now | Enum.take(Map.get(stats, :crash_times, []), 99)]
    }
  end

  defp count_crashes_in_window(state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - state.crash_window_ms

    state.workers
    |> Map.values()
    |> Enum.flat_map(fn stats -> Map.get(stats, :crash_times, []) end)
    |> Enum.count(fn time -> time >= window_start end)
  end

  defp cleanup_old_crashes(state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - state.crash_window_ms

    workers =
      state.workers
      |> Enum.map(fn {id, stats} ->
        crash_times =
          stats
          |> Map.get(:crash_times, [])
          |> Enum.filter(fn time -> time >= window_start end)

        {id, Map.put(stats, :crash_times, crash_times)}
      end)
      |> Enum.filter(fn {_id, stats} ->
        # Keep workers with recent crashes
        Map.get(stats, :crash_times, []) != []
      end)
      |> Map.new()

    %{state | workers: workers}
  end
end
