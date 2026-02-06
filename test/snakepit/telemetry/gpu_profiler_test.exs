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

  describe "callback scheduling" do
    test "sample callback defers slow sampling work to async task" do
      slow_sampler = fn _device ->
        Process.sleep(150)

        {:ok,
         %{
           memory_used_mb: 10,
           memory_total_mb: 20,
           memory_free_mb: 10,
           gpu_utilization: 5.0,
           temperature: 40.0,
           power_watts: 25.0
         }}
      end

      state = %{
        interval_ms: 5_000,
        enabled: true,
        sample_count: 0,
        last_sample_time: nil,
        timer_ref: nil,
        devices: [{:cuda, 0}],
        sampler_fun: slow_sampler,
        sample_task_ref: nil,
        sample_task_pid: nil
      }

      {elapsed_us, {:noreply, new_state}} =
        :timer.tc(fn ->
          GPUProfiler.handle_info(:sample, state)
        end)

      assert elapsed_us < 80_000
      assert new_state.sample_count == 0
      assert is_reference(new_state.sample_task_ref)
      assert is_pid(new_state.sample_task_pid)
    end

    test "sample_now callback defers slow sampling work to async task" do
      slow_sampler = fn _device ->
        Process.sleep(150)

        {:ok,
         %{
           memory_used_mb: 10,
           memory_total_mb: 20,
           memory_free_mb: 10,
           gpu_utilization: 5.0,
           temperature: 40.0,
           power_watts: 25.0
         }}
      end

      state = %{
        interval_ms: 5_000,
        enabled: true,
        sample_count: 0,
        last_sample_time: nil,
        timer_ref: nil,
        devices: [{:cuda, 0}],
        sampler_fun: slow_sampler,
        sample_task_ref: nil,
        sample_task_pid: nil,
        sample_now_waiters: []
      }

      from = {self(), make_ref()}

      {elapsed_us, {:noreply, new_state}} =
        :timer.tc(fn ->
          GPUProfiler.handle_call(:sample_now, from, state)
        end)

      assert elapsed_us < 80_000
      assert is_reference(new_state.sample_task_ref)
      assert is_pid(new_state.sample_task_pid)
      assert new_state.sample_now_waiters == [from]
    end

    test "terminate/2 cancels timer and kills in-flight sample task" do
      sample_task_pid = spawn(fn -> Process.sleep(:infinity) end)
      sample_task_ref = Process.monitor(sample_task_pid)
      sample_task_assert_ref = Process.monitor(sample_task_pid)

      timer_ref = Process.send_after(self(), :sample, 100)

      state = %{
        interval_ms: 5_000,
        enabled: true,
        sample_count: 0,
        last_sample_time: nil,
        timer_ref: timer_ref,
        devices: [{:cuda, 0}],
        sampler_fun: fn _device -> {:error, :unused} end,
        sample_task_ref: sample_task_ref,
        sample_task_pid: sample_task_pid,
        sample_now_waiters: []
      }

      assert :ok = GPUProfiler.terminate(:shutdown, state)

      assert_receive {:DOWN, ^sample_task_assert_ref, :process, ^sample_task_pid, _reason}, 200
      refute_receive :sample, 150
    end
  end
end
