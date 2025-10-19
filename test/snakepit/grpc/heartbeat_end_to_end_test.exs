defmodule Snakepit.GRPC.HeartbeatEndToEndTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.Pool.Registry, as: PoolRegistry

  @moduletag :python_integration
  @moduletag timeout: 120_000

  setup do
    prev_pools = Application.get_env(:snakepit, :pools)
    prev_pooling = Application.get_env(:snakepit, :pooling_enabled)

    Application.stop(:snakepit)

    Application.put_env(:snakepit, :pooling_enabled, true)

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: Snakepit.Adapters.GRPCPython
      }
    ])

    {:ok, _apps} = Application.ensure_all_started(:snakepit)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(:pools, prev_pools)
      restore_env(:pooling_enabled, prev_pooling)
    end)

    :ok
  end

  test "python heartbeat pongs reach Elixir monitor" do
    python_exec = Snakepit.Adapters.GRPCPython.executable_path()

    assert python_exec, "Expected Python executable for heartbeat integration test"
    assert File.exists?(python_exec), "Python executable not found at #{inspect(python_exec)}"

    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    worker_id = "hb_e2e_#{System.unique_integer([:positive])}"

    heartbeat_config = %{
      enabled: true,
      ping_interval_ms: 500,
      timeout_ms: 2_000,
      max_missed_heartbeats: 5,
      initial_delay_ms: 3_000,
      test_pid: self()
    }

    worker_config = %{
      heartbeat: heartbeat_config
    }

    {:ok, starter_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        Snakepit.Adapters.GRPCPython,
        Snakepit.Pool,
        worker_config
      )

    assert is_pid(starter_pid)

    assert_eventually(
      fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
      timeout: 15_000,
      interval: 200
    )

    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)

    {:ok, _result} = Snakepit.GRPCWorker.execute(worker_pid, "ping", %{})

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid}, 30_000
    assert is_pid(monitor_pid)

    # Allow heartbeat loop to run at least once after initial delay
    Process.sleep(4_000)

    status = Snakepit.HeartbeatMonitor.get_status(monitor_pid)

    assert status.stats.pings_sent >= 1
    assert status.stats.pongs_received >= 1
    assert status.missed_heartbeats == 0

    :ok = GenServer.stop(worker_pid)

    assert_receive {:heartbeat_monitor_stopped, ^worker_id, :normal}, 5_000

    assert_eventually(fn -> PoolRegistry.worker_exists?(worker_id) == false end, timeout: 5_000)
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
