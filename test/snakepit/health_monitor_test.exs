defmodule Snakepit.HealthMonitorTest do
  use ExUnit.Case, async: true

  alias Snakepit.HealthMonitor

  describe "start_link/1" do
    test "starts with required options" do
      {:ok, pid} =
        HealthMonitor.start_link(
          name: :test_hm,
          pool: :default,
          check_interval_ms: 1000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "record_crash/2" do
    setup do
      {:ok, pid} =
        HealthMonitor.start_link(
          name: :"hm_#{System.unique_integer([:positive])}",
          pool: :default,
          check_interval_ms: 1000,
          crash_window_ms: 5000,
          max_crashes: 3
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, hm: pid}
    end

    test "records crash with worker info", %{hm: hm} do
      HealthMonitor.record_crash(hm, "worker_1", %{reason: :segfault})

      stats = HealthMonitor.stats(hm)
      assert stats.total_crashes > 0
    end

    test "tracks crashes per worker", %{hm: hm} do
      HealthMonitor.record_crash(hm, "worker_1", %{})
      HealthMonitor.record_crash(hm, "worker_1", %{})
      HealthMonitor.record_crash(hm, "worker_2", %{})

      stats = HealthMonitor.stats(hm)
      assert stats.workers_with_crashes == 2
    end
  end

  describe "healthy?/1" do
    setup do
      {:ok, pid} =
        HealthMonitor.start_link(
          name: :"hm_healthy_#{System.unique_integer([:positive])}",
          pool: :default,
          check_interval_ms: 1000,
          crash_window_ms: 5000,
          max_crashes: 2
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, hm: pid}
    end

    test "returns true when healthy", %{hm: hm} do
      assert HealthMonitor.healthy?(hm) == true
    end

    test "returns false after too many crashes", %{hm: hm} do
      HealthMonitor.record_crash(hm, "worker_1", %{})
      HealthMonitor.record_crash(hm, "worker_2", %{})
      HealthMonitor.record_crash(hm, "worker_3", %{})

      assert HealthMonitor.healthy?(hm) == false
    end
  end

  describe "worker_health/2" do
    setup do
      {:ok, pid} =
        HealthMonitor.start_link(
          name: :"hm_worker_#{System.unique_integer([:positive])}",
          pool: :default,
          check_interval_ms: 1000
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, hm: pid}
    end

    test "returns health status for worker", %{hm: hm} do
      status = HealthMonitor.worker_health(hm, "worker_1")

      assert is_map(status)
      assert Map.has_key?(status, :healthy)
      assert Map.has_key?(status, :crash_count)
    end

    test "updates after crash", %{hm: hm} do
      HealthMonitor.record_crash(hm, "worker_1", %{})

      status = HealthMonitor.worker_health(hm, "worker_1")
      assert status.crash_count == 1
    end
  end

  describe "stats/1" do
    test "returns comprehensive stats" do
      {:ok, hm} =
        HealthMonitor.start_link(
          name: :"hm_stats_#{System.unique_integer([:positive])}",
          pool: :default,
          check_interval_ms: 1000
        )

      stats = HealthMonitor.stats(hm)

      assert is_map(stats)
      assert Map.has_key?(stats, :total_crashes)
      assert Map.has_key?(stats, :crashes_in_window)
      assert Map.has_key?(stats, :workers_with_crashes)
      assert Map.has_key?(stats, :is_healthy)

      GenServer.stop(hm)
    end
  end
end
