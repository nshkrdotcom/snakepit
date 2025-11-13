defmodule Snakepit.GRPC.HeartbeatIntegrationTest do
  use ExUnit.Case, async: false

  alias Snakepit.GRPCWorker
  alias Snakepit.TestAdapters.MockGRPCAdapter

  defmodule PoolStub do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:worker_ready, _worker_id}, _from, state) do
      {:reply, :ok, state}
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    ensure_started(Snakepit.Pool.Registry)
    ensure_started(Snakepit.Pool.ProcessRegistry)
    {:ok, pool_pid} = start_supervised(PoolStub)
    {:ok, pool: pool_pid}
  end

  defp worker_opts(overrides) do
    worker_id = "default_worker_hb_#{System.unique_integer([:positive])}"

    [
      id: worker_id,
      adapter: MockGRPCAdapter,
      worker_config: %{}
    ]
    |> Keyword.merge(overrides)
  end

  test "starts heartbeat monitor when enabled and emits pings", %{pool: pool_pid} = _context do
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

    opts =
      []
      |> worker_opts()
      |> Keyword.merge(worker_config: %{heartbeat: heartbeat_config})
      |> Keyword.put(:pool_name, pool_pid)

    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid} when is_pid(monitor_pid),
                   2_000

    assert_receive {:heartbeat_ping_sent, _timestamp}, 500

    :ok = GenServer.stop(worker)
  end

  @tag :slow
  test "does not start heartbeat monitor when disabled", %{pool: pool_pid} = _context do
    test_pid = self()

    opts =
      []
      |> worker_opts()
      |> Keyword.merge(
        worker_config: %{
          heartbeat: %{
            enabled: false,
            test_pid: test_pid
          }
        }
      )
      |> Keyword.put(:pool_name, pool_pid)

    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    refute_receive {:heartbeat_monitor_started, ^worker_id, _}, 1_000

    :ok = GenServer.stop(worker)
  end

  test "terminates heartbeat monitor when worker stops", %{pool: pool_pid} = _context do
    test_pid = self()

    opts =
      []
      |> worker_opts()
      |> Keyword.merge(
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
      |> Keyword.put(:pool_name, pool_pid)

    {:ok, worker} = GRPCWorker.start_link(opts)
    worker_id = opts[:id]

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid} when is_pid(monitor_pid),
                   2_000

    ref = Process.monitor(monitor_pid)
    :ok = GenServer.stop(worker)

    assert_receive {:heartbeat_monitor_stopped, ^worker_id, _reason}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^monitor_pid, _reason}, 1_000
  end

  defp ensure_started(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
