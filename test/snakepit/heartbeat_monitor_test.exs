defmodule Snakepit.HeartbeatMonitorTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.HeartbeatMonitor

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp spawn_worker do
    parent = self()

    spawn_link(fn ->
      send(parent, {:worker_started, self()})

      receive do
        :halt -> :ok
      end
    end)

    receive do
      {:worker_started, pid} -> pid
    after
      100 -> flunk("worker did not start")
    end
  end

  test "sends periodic ping and records pong statistics" do
    test_pid = self()
    worker_pid = spawn_worker()

    ping_fun = fn timestamp ->
      send(test_pid, {:ping, timestamp})
      :ok
    end

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-1",
        ping_interval_ms: 20,
        timeout_ms: 100,
        ping_fun: ping_fun
      )

    assert_receive {:ping, ts}, 200

    HeartbeatMonitor.notify_pong(monitor, ts)

    status = HeartbeatMonitor.get_status(monitor)

    assert status.missed_heartbeats == 0
    assert status.stats.pings_sent >= 1
    assert status.stats.pongs_received == 1
  end

  test "terminates worker after exceeding missed heartbeat threshold" do
    worker_pid = spawn_worker()
    Process.monitor(worker_pid)

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-2",
        ping_interval_ms: 10,
        timeout_ms: 20,
        max_missed_heartbeats: 1,
        ping_fun: fn _timestamp -> :ok end
      )

    ref = Process.monitor(monitor)

    assert_receive {:DOWN, ^ref, :process, ^monitor, reason}, 500

    assert reason in [
             {:shutdown, :heartbeat_timeout},
             {:worker_down, {:shutdown, :heartbeat_timeout}}
           ]

    assert_receive {:DOWN, _mon_ref, :process, ^worker_pid, {:shutdown, :heartbeat_timeout}}, 500
  end

  test "maintains heartbeat stability over sustained intervals" do
    worker_pid = spawn_worker()
    parent = self()

    ping_fun = fn timestamp ->
      send(parent, {:steady_ping, timestamp})
      HeartbeatMonitor.notify_pong(self(), timestamp)
      :ok
    end

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-stable",
        ping_interval_ms: 50,
        timeout_ms: 200,
        max_missed_heartbeats: 5,
        ping_fun: ping_fun
      )

    assert_eventually(
      fn ->
        status = HeartbeatMonitor.get_status(monitor)

        status.missed_heartbeats == 0 and
          status.stats.pings_sent >= 8 and
          status.stats.pongs_received == status.stats.pings_sent
      end,
      timeout: 2_000,
      interval: 50
    )

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end

  test "independent monitors suppress worker termination on repeated failures" do
    worker_pid = spawn_worker()
    worker_ref = Process.monitor(worker_pid)

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-independent",
        ping_interval_ms: 10,
        timeout_ms: 20,
        max_missed_heartbeats: 1,
        dependent: false,
        ping_fun: fn _timestamp -> :ok end
      )

    assert_eventually(
      fn ->
        status = HeartbeatMonitor.get_status(monitor)

        status.stats.timeouts >= 1 and
          status.missed_heartbeats >= 1 and
          Process.alive?(worker_pid) and
          Process.alive?(monitor)
      end,
      timeout: 1_000,
      interval: 25
    )

    refute_received {:DOWN, ^worker_ref, :process, ^worker_pid, _}

    status = HeartbeatMonitor.get_status(monitor)
    assert status.dependent == false

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _}, 500
  end

  test "dependent monitors terminate workers when ping failures persist" do
    worker_pid = spawn_worker()
    worker_ref = Process.monitor(worker_pid)

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-dependent",
        ping_interval_ms: 10,
        timeout_ms: 20,
        max_missed_heartbeats: 1,
        dependent: true,
        ping_fun: fn _timestamp -> {:error, :simulated_failure} end
      )

    monitor_ref = Process.monitor(monitor)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, {:shutdown, :ping_failed}}, 1_000
    assert_receive {:DOWN, ^monitor_ref, :process, ^monitor, {:shutdown, :ping_failed}}, 1_000
  end
end
