defmodule Snakepit.GRPC.HeartbeatFailfastTest do
  @moduledoc """
  Heartbeat regression tests that prove dependent workers die on monitor failures while
  independent workers continue to serve requests.
  """
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.ProcessKiller

  @moduletag :python_integration
  @moduletag timeout: 120_000

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    configure_python_pool()
    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 60_000)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  test "dependent worker terminates on heartbeat timeout" do
    handler_id = "hb-dependent-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:snakepit, :heartbeat, :heartbeat_timeout],
          [:snakepit, :heartbeat, :monitor_failure]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    worker_id = "hb_dep_#{System.unique_integer([:positive])}"

    heartbeat_config = %{
      enabled: true,
      ping_interval_ms: 20,
      timeout_ms: 60,
      max_missed_heartbeats: 1,
      dependent: true,
      test_pid: self(),
      ping_fun: fn timestamp ->
        send(self(), {:synthetic_ping, timestamp})
        :ok
      end
    }

    {:ok, _worker_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        Snakepit.Adapters.GRPCPython,
        Snakepit.Pool,
        %{heartbeat: heartbeat_config}
      )

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid}, 30_000
    assert is_pid(monitor_pid)

    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)
    worker_ref = Process.monitor(worker_pid)

    {:ok, worker_info} = ProcessRegistry.get_worker_info(worker_id)
    os_pid = worker_info.process_pid

    assert_receive {:telemetry, [:snakepit, :heartbeat, :heartbeat_timeout], _, _}, 10_000
    assert_receive {:telemetry, [:snakepit, :heartbeat, :monitor_failure], _, _}, 10_000

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, reason}, 15_000
    assert heartbeat_timeout_reason?(reason)

    assert_eventually(
      fn -> not PoolRegistry.worker_exists?(worker_id) end,
      timeout: 5_000,
      interval: 200
    )

    assert_eventually(
      fn -> not ProcessRegistry.worker_registered?(worker_id) end,
      timeout: 5_000,
      interval: 200
    )

    assert_eventually(fn -> not ProcessKiller.process_alive?(os_pid) end, timeout: 5_000)
  end

  test "independent worker logs heartbeat failures but keeps serving" do
    handler_id = "hb-independent-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:snakepit, :heartbeat, :heartbeat_timeout],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    worker_id = "hb_ind_#{System.unique_integer([:positive])}"

    heartbeat_config = %{
      enabled: true,
      ping_interval_ms: 25,
      timeout_ms: 60,
      max_missed_heartbeats: 1,
      dependent: false,
      test_pid: self(),
      ping_fun: fn timestamp ->
        send(self(), {:independent_ping, timestamp})
        :ok
      end
    }

    {:ok, _worker_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        Snakepit.Adapters.GRPCPython,
        Snakepit.Pool,
        %{heartbeat: heartbeat_config}
      )

    assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid}, 30_000
    assert is_pid(monitor_pid)

    {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)

    assert_receive {:telemetry, [:snakepit, :heartbeat, :heartbeat_timeout], _, _}, 10_000

    {:ok, response} = Snakepit.GRPCWorker.execute(worker_pid, "ping", %{})
    assert is_map(response)

    refute_received {:telemetry, [:snakepit, :heartbeat, :monitor_failure], _, _}

    :ok = GenServer.stop(worker_pid)
  end

  defp heartbeat_timeout_reason?(reason) do
    case reason do
      {:shutdown, :heartbeat_timeout} -> true
      {:shutdown, {:heartbeat_timeout, _}} -> true
      {:shutdown, {:shutdown, :heartbeat_timeout}} -> true
      {:shutdown, {:shutdown, {:shutdown, :heartbeat_timeout}}} -> true
      :heartbeat_timeout -> true
      _ -> false
    end
  end

  defp configure_python_pool do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: Snakepit.Adapters.GRPCPython
      }
    ])
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
