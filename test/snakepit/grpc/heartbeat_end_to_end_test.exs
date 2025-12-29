defmodule Snakepit.GRPC.HeartbeatEndToEndTest do
  use ExUnit.Case, async: false
  import Snakepit.TestHelpers

  alias Snakepit.Adapters.GRPCPython
  alias Snakepit.Pool.ProcessRegistry
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.WorkerSupervisor

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
    python_exec = GRPCPython.executable_path()

    assert python_exec, "Expected Python executable for heartbeat integration test"
    assert File.exists?(python_exec), "Python executable not found at #{inspect(python_exec)}"

    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

    worker_id = "hb_e2e_#{System.unique_integer([:positive])}"

    handler_id = "heartbeat_pong_#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:snakepit, :heartbeat, :pong_received],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:heartbeat_pong_received, metadata.worker_id})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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

    assert_receive {:heartbeat_pong_received, ^worker_id}, 10_000

    # If heartbeats are working, the monitor and worker should stay alive
    assert Process.alive?(monitor_pid), "Monitor should stay alive with successful heartbeats"
    assert Process.alive?(worker_pid), "Worker should stay alive with successful heartbeats"

    :ok = GenServer.stop(worker_pid)

    assert_receive {:heartbeat_monitor_stopped, ^worker_id, :normal}, 5_000

    assert_eventually(fn -> PoolRegistry.worker_exists?(worker_id) == false end, timeout: 5_000)
  end

  test "heartbeat timeout kills external python process and unregisters worker" do
    if match?({:unix, _}, :os.type()) do
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 30_000)

      worker_id = "hb_timeout_kill_#{System.unique_integer([:positive])}"

      heartbeat_config = %{
        enabled: true,
        ping_interval_ms: 20,
        timeout_ms: 60,
        max_missed_heartbeats: 1,
        ping_fun: fn _timestamp -> :ok end,
        test_pid: self()
      }

      worker_config = %{heartbeat: heartbeat_config}

      Process.flag(:trap_exit, true)

      {:ok, _pid} =
        Snakepit.GRPCWorker.start_link(
          id: worker_id,
          adapter: Snakepit.Adapters.GRPCPython,
          pool_name: Snakepit.Pool,
          worker_config: worker_config
        )

      assert_eventually(
        fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
        timeout: 15_000,
        interval: 200
      )

      {:ok, worker_pid} = PoolRegistry.get_worker_pid(worker_id)
      worker_ref = Process.monitor(worker_pid)

      {:ok, worker_info} = ProcessRegistry.get_worker_info(worker_id)
      assert is_integer(worker_info.process_pid) and worker_info.process_pid > 0
      os_pid = worker_info.process_pid

      assert_receive {:heartbeat_monitor_started, ^worker_id, monitor_pid}, 30_000
      assert is_pid(monitor_pid)
      monitor_ref = Process.monitor(monitor_pid)

      # Allow the monitor to ping once; no pong will be received, triggering timeout
      assert_receive {:DOWN, ^monitor_ref, :process, ^monitor_pid, monitor_reason}, 15_000
      assert heartbeat_timeout_reason?(monitor_reason)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, worker_reason}, 15_000
      assert heartbeat_timeout_reason?(worker_reason)

      refute Process.alive?(worker_pid)

      assert_eventually(fn -> not ProcessRegistry.worker_registered?(worker_id) end,
        timeout: 5_000,
        interval: 100
      )

      assert_eventually(fn -> kill_check(os_pid) != 0 end, timeout: 5_000, interval: 200)
    else
      IO.puts("Skipping heartbeat timeout process kill test on non-Unix platform")
    end
  end

  defp heartbeat_timeout_reason?(reason) do
    case reason do
      {:shutdown, :heartbeat_timeout} -> true
      {:shutdown, {:shutdown, :heartbeat_timeout}} -> true
      {:shutdown, {:monitor_failure, :heartbeat_timeout}} -> true
      {:shutdown, {:heartbeat_timeout, _}} -> true
      {:shutdown, {:shutdown, {:shutdown, :heartbeat_timeout}}} -> true
      other -> other == :heartbeat_timeout
    end
  end

  defp kill_check(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, status} -> status
    end
  rescue
    _ -> 1
  end

  defp restore_env(key, nil), do: Application.delete_env(:snakepit, key)
  defp restore_env(key, value), do: Application.put_env(:snakepit, key, value)
end
