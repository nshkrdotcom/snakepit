defmodule Snakepit.GRPC.HeartbeatIntegrationTest do
  use ExUnit.Case, async: false

  alias Snakepit.GRPCWorker
  alias Snakepit.TestAdapters.MockGRPCAdapter

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp worker_opts(overrides \\ []) do
    worker_id = "default_worker_hb_#{System.unique_integer([:positive])}"

    [
      id: worker_id,
      adapter: MockGRPCAdapter,
      pool_name: Snakepit.Pool,
      worker_config: %{}
    ]
    |> Keyword.merge(overrides)
  end

  test "starts heartbeat monitor when enabled and emits pings" do
    test_pid = self()

    heartbeat_config = %{
      enabled: true,
      ping_interval_ms: 20,
      timeout_ms: 40,
      ping_fun: fn timestamp ->
        send(test_pid, {:heartbeat_ping_sent, timestamp})
        Snakepit.HeartbeatMonitor.notify_pong(self(), timestamp)
        :ok
      end,
      test_pid: test_pid
    }

    opts = worker_opts(worker_config: %{heartbeat: heartbeat_config})
    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid} when is_pid(monitor_pid),
                   2_000

    assert_receive {:heartbeat_ping_sent, _timestamp}, 500

    :ok = GenServer.stop(worker)
  end

  test "does not start heartbeat monitor when disabled" do
    test_pid = self()

    opts =
      worker_opts(
        worker_config: %{
          heartbeat: %{
            enabled: false,
            test_pid: test_pid
          }
        }
      )

    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    refute_receive {:heartbeat_monitor_started, ^worker_id, _}, 1_000

    :ok = GenServer.stop(worker)
  end

  test "terminates heartbeat monitor when worker stops" do
    test_pid = self()

    opts =
      worker_opts(
        worker_config: %{
          heartbeat: %{
            enabled: true,
            ping_interval_ms: 20,
            timeout_ms: 40,
            ping_fun: fn timestamp ->
              Snakepit.HeartbeatMonitor.notify_pong(self(), timestamp)
              :ok
            end,
            test_pid: test_pid
          }
        }
      )

    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid} when is_pid(monitor_pid),
                   2_000

    ref = Process.monitor(monitor_pid)
    :ok = GenServer.stop(worker)

    assert_receive {:heartbeat_monitor_stopped, ^worker_id, _reason}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^monitor_pid, _reason}, 1_000
  end
end
