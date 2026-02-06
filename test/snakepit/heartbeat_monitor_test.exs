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

  test "sends periodic ping and responds to pong" do
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

    # Verify ping is sent
    assert_receive {:ping, ts}, 200

    # Notify pong - should not cause any errors
    HeartbeatMonitor.notify_pong(monitor, ts)

    # Monitor should still be alive
    assert Process.alive?(monitor)

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end

  test "ignores stale heartbeat timeout messages after pong cancellation" do
    worker_pid = spawn_worker()
    test_pid = self()

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-stale-timeout",
        ping_interval_ms: 20,
        timeout_ms: 100,
        max_missed_heartbeats: 3,
        dependent: false,
        ping_fun: fn timestamp ->
          send(test_pid, {:ping, timestamp})
          :ok
        end
      )

    assert_receive {:ping, ts}, 200

    HeartbeatMonitor.notify_pong(monitor, ts)
    send(monitor, :heartbeat_timeout)

    assert_eventually(
      fn ->
        :sys.get_state(monitor).missed_heartbeats == 0
      end,
      timeout: 200,
      interval: 10
    )

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end

  test "notify_pong(self(), timestamp) stays compatible when ping_fun runs in async task" do
    worker_pid = spawn_worker()
    ping_count = :counters.new(1, [:atomics])

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-self-pong",
        ping_interval_ms: 20,
        timeout_ms: 60,
        max_missed_heartbeats: 1,
        ping_fun: fn timestamp ->
          :counters.add(ping_count, 1, 1)
          HeartbeatMonitor.notify_pong(self(), timestamp)
          :ok
        end
      )

    assert_eventually(
      fn ->
        :counters.get(ping_count, 1) >= 2 and Process.alive?(monitor) and
          Process.alive?(worker_pid)
      end,
      timeout: 300,
      interval: 20
    )

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
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
    ping_count = :counters.new(1, [:atomics])

    ping_fun = fn timestamp ->
      :counters.add(ping_count, 1, 1)
      send(parent, {:steady_ping, timestamp})
      HeartbeatMonitor.notify_pong(self(), timestamp)
      :ok
    end

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-stable",
        ping_interval_ms: 20,
        timeout_ms: 100,
        max_missed_heartbeats: 5,
        ping_fun: ping_fun
      )

    # Wait for multiple successful heartbeats
    assert_eventually(
      fn ->
        count = :counters.get(ping_count, 1)
        count >= 4 and Process.alive?(monitor) and Process.alive?(worker_pid)
      end,
      timeout: 500,
      interval: 20
    )

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end

  test "independent monitors suppress worker termination on repeated failures" do
    worker_pid = spawn_worker()
    worker_ref = Process.monitor(worker_pid)
    timeout_count = :counters.new(1, [:atomics])

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-independent",
        ping_interval_ms: 10,
        timeout_ms: 20,
        max_missed_heartbeats: 1,
        dependent: false,
        ping_fun: fn _timestamp ->
          :counters.add(timeout_count, 1, 1)
          :ok
        end
      )

    # Wait for timeouts to occur while verifying worker and monitor stay alive
    assert_eventually(
      fn ->
        count = :counters.get(timeout_count, 1)
        count >= 2 and Process.alive?(worker_pid) and Process.alive?(monitor)
      end,
      timeout: 400,
      interval: 10
    )

    refute_received {:DOWN, ^worker_ref, :process, ^worker_pid, _}

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

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, {:shutdown, :ping_failed}}, 500
    assert_receive {:DOWN, ^monitor_ref, :process, ^monitor, {:shutdown, :ping_failed}}, 500
  end

  test "heartbeat ping fallback works when TaskSupervisor is unavailable" do
    on_exit(fn ->
      Application.ensure_all_started(:snakepit)
    end)

    Application.stop(:snakepit)

    worker_pid = spawn_worker()
    ping_counter = :counters.new(1, [:atomics])

    {:ok, monitor} =
      HeartbeatMonitor.start_link(
        worker_pid: worker_pid,
        worker_id: "worker-fallback-ping",
        ping_interval_ms: 20,
        timeout_ms: 120,
        max_missed_heartbeats: 1,
        dependent: false,
        ping_fun: fn timestamp ->
          :counters.add(ping_counter, 1, 1)
          HeartbeatMonitor.notify_pong(self(), timestamp)
          :ok
        end
      )

    assert_eventually(
      fn ->
        :counters.get(ping_counter, 1) >= 2 and Process.alive?(monitor)
      end,
      timeout: 500,
      interval: 20
    )

    :ok = GenServer.stop(monitor)
    send(worker_pid, :halt)
  end

  test "ping timeout path demonitor flushes ping task monitor messages" do
    worker_pid = spawn_worker()
    ping_task_pid = spawn(fn -> Process.sleep(:infinity) end)
    ping_task_ref = Process.monitor(ping_task_pid)

    state = %HeartbeatMonitor{
      worker_pid: worker_pid,
      worker_id: "worker-timeout-flush",
      ping_interval: 1_000,
      timeout: 100,
      max_missed_heartbeats: 1,
      ping_fun: fn _timestamp -> :ok end,
      ping_task_ref: ping_task_ref,
      ping_task_pid: ping_task_pid,
      ping_task_timer: nil,
      dependent: true,
      missed_heartbeats: 0,
      stats: %{pings_sent: 0, pongs_received: 0, timeouts: 0}
    }

    assert {:stop, {:shutdown, :ping_failed}, _new_state} =
             HeartbeatMonitor.handle_info({:ping_task_timeout, ping_task_ref}, state)

    refute_receive {:DOWN, ^ping_task_ref, :process, ^ping_task_pid, _reason}, 100

    receive do
      {:EXIT, ^worker_pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
