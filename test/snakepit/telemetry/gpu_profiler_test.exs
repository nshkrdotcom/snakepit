defmodule Snakepit.Telemetry.GPUProfilerTest do
  use ExUnit.Case, async: false

  alias Snakepit.Telemetry.GPUProfiler

  describe "start_link/1" do
    test "starts profiler with default options" do
      assert {:ok, pid} = GPUProfiler.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts profiler with custom interval" do
      assert {:ok, pid} = GPUProfiler.start_link(interval_ms: 5000)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts profiler as disabled" do
      assert {:ok, pid} = GPUProfiler.start_link(enabled: false)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "sample_now/1" do
    test "returns ok when no GPU available" do
      {:ok, pid} = GPUProfiler.start_link([])

      # Should not crash even if no GPU
      result = GPUProfiler.sample_now(pid)
      assert result in [:ok, {:error, :no_gpu}]

      GenServer.stop(pid)
    end
  end

  describe "get_stats/1" do
    test "returns stats map" do
      {:ok, pid} = GPUProfiler.start_link([])

      stats = GPUProfiler.get_stats(pid)

      assert is_map(stats)
      assert Map.has_key?(stats, :sample_count)
      assert Map.has_key?(stats, :last_sample_time)
      assert is_integer(stats.sample_count)

      GenServer.stop(pid)
    end
  end

  describe "enable/1 and disable/1" do
    test "can enable and disable profiling" do
      {:ok, pid} = GPUProfiler.start_link(enabled: false)

      assert :ok = GPUProfiler.enable(pid)
      stats = GPUProfiler.get_stats(pid)
      assert stats.enabled == true

      assert :ok = GPUProfiler.disable(pid)
      stats = GPUProfiler.get_stats(pid)
      assert stats.enabled == false

      GenServer.stop(pid)
    end
  end

  describe "set_interval/2" do
    test "updates sampling interval" do
      {:ok, pid} = GPUProfiler.start_link(interval_ms: 1000)

      assert :ok = GPUProfiler.set_interval(pid, 5000)

      stats = GPUProfiler.get_stats(pid)
      assert stats.interval_ms == 5000

      GenServer.stop(pid)
    end

    test "rejects invalid intervals" do
      {:ok, pid} = GPUProfiler.start_link([])

      assert {:error, :invalid_interval} = GPUProfiler.set_interval(pid, 0)
      assert {:error, :invalid_interval} = GPUProfiler.set_interval(pid, -100)

      GenServer.stop(pid)
    end
  end
end
