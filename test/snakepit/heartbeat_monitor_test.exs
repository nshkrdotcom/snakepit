defmodule Snakepit.HeartbeatMonitorTest do
  use ExUnit.Case, async: false

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

    # Allow multiple cycles to run
    Process.sleep(1_000)

    status = HeartbeatMonitor.get_status(monitor)

    assert status.missed_heartbeats == 0
    assert status.stats.pings_sent >= 8
    assert status.stats.pongs_received == status.stats.pings_sent

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end
end
