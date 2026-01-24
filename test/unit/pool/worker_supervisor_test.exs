defmodule Snakepit.Pool.WorkerSupervisorTest do
  use Snakepit.TestCase, async: false

  @moduletag :capture_log

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Registry, as: PoolRegistry
  alias Snakepit.Pool.Worker.StarterRegistry
  alias Snakepit.Pool.WorkerSupervisor
  alias Snakepit.TestAdapters.{EphemeralPortGRPCAdapter, MockGRPCAdapter}

  setup do
    prev_env = capture_env()

    Application.stop(:snakepit)
    Application.load(:snakepit)
    configure_pooling()

    {:ok, _} = Application.ensure_all_started(:snakepit)
    assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)

    on_exit(fn ->
      Application.stop(:snakepit)
      restore_env(prev_env)
      {:ok, _} = Application.ensure_all_started(:snakepit)
    end)

    :ok
  end

  describe "stop_worker/1" do
    test "shuts down worker and starter when given a worker id" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      assert StarterRegistry.starter_exists?(worker_id)

      assert :ok = WorkerSupervisor.stop_worker(worker_id)

      assert_worker_shutdown(worker_id, worker_pid)
    end

    test "accepts a worker pid" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      assert :ok = WorkerSupervisor.stop_worker(worker_pid)

      assert_worker_shutdown(worker_id, worker_pid)
    end
  end

  describe "restart_worker/1" do
    test "terminates the existing worker and starts a fresh one" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id)

      {:ok, new_worker_pid} = WorkerSupervisor.restart_worker(worker_id)
      assert is_pid(new_worker_pid)

      assert_eventually(fn ->
        match?({:ok, _}, StarterRegistry.get_starter_pid(worker_id))
      end)

      assert_eventually(fn ->
        case PoolRegistry.get_worker_pid(worker_id) do
          {:ok, new_pid} ->
            new_pid != worker_pid and Process.alive?(new_pid)

          {:error, :not_found} ->
            false
        end
      end)

      assert_eventually(fn -> not Process.alive?(worker_pid) end)
    end

    test "skips port probe when worker requested an ephemeral port" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id, EphemeralPortGRPCAdapter)

      assert {:ok, %{requested_port: 0, current_port: current_port}} =
               GenServer.call(worker_pid, :get_port_metadata, 1_000)

      assert current_port not in [nil, 0]

      # Use process-level log level for isolation
      SLog.set_process_level(:debug)

      ref = Process.monitor(worker_pid)

      restart_task =
        Task.async(fn ->
          WorkerSupervisor.restart_worker(worker_id)
        end)

      blocker_socket =
        receive do
          {:DOWN, ^ref, :process, ^worker_pid, _reason} ->
            bind_port!(current_port)
        after
          1_000 ->
            flunk("worker did not terminate during restart")
        end

      try do
        {:ok, new_worker_pid} = Task.await(restart_task, 5_000)
        assert is_pid(new_worker_pid)

        assert_eventually(fn ->
          match?({:ok, _}, StarterRegistry.get_starter_pid(worker_id))
        end)

        assert_eventually(fn ->
          case PoolRegistry.get_worker_pid(worker_id) do
            {:ok, new_pid} ->
              new_pid != worker_pid and Process.alive?(new_pid)

            {:error, :not_found} ->
              false
          end
        end)
      after
        :gen_tcp.close(blocker_socket)
      end
    end

    @tag :slow
    test "probes requested port when worker bound to a fixed port" do
      worker_id = unique_worker_id()
      assert :ok = Snakepit.Pool.await_ready(Snakepit.Pool, 5_000)
      {_starter_pid, worker_pid} = start_mock_worker(worker_id, MockGRPCAdapter)

      assert {:ok, %{requested_port: requested_port, current_port: current_port}} =
               GenServer.call(worker_pid, :get_port_metadata, 1_000)

      assert requested_port not in [nil, 0]
      assert current_port == requested_port

      # Use process-level log level for isolation
      SLog.set_process_level(:debug)

      ref = Process.monitor(worker_pid)

      restart_task =
        Task.async(fn ->
          WorkerSupervisor.restart_worker(worker_id)
        end)

      blocker_socket =
        receive do
          {:DOWN, ^ref, :process, ^worker_pid, _reason} ->
            bind_port!(requested_port)
        after
          1_000 ->
            flunk("worker did not terminate during restart")
        end

      try do
        assert {:error, :cleanup_timeout} = Task.await(restart_task, 5_000)
      after
        :gen_tcp.close(blocker_socket)
      end

      assert_eventually(fn ->
        match?({:error, :not_found}, PoolRegistry.get_worker_pid(worker_id))
      end)
    end

    test "port_probe_target falls back to requested port when current port missing" do
      assert WorkerSupervisor.port_probe_target(nil, 4321) == 4321
      assert WorkerSupervisor.port_probe_target(5000, 4321) == 5000
      assert WorkerSupervisor.port_probe_target(nil, 0) == nil
    end
  end

  defp start_mock_worker(worker_id, adapter \\ MockGRPCAdapter) do
    worker_config = %{
      test_pid: self(),
      heartbeat: %{enabled: false}
    }

    {:ok, worker_pid} =
      WorkerSupervisor.start_worker(
        worker_id,
        Snakepit.GRPCWorker,
        adapter,
        Snakepit.Pool,
        worker_config
      )

    assert is_pid(worker_pid)

    assert_eventually(
      fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
      timeout: 5_000,
      interval: 50
    )

    assert_eventually(
      fn -> match?({:ok, ^worker_id}, PoolRegistry.get_worker_id_by_pid(worker_pid)) end,
      timeout: 5_000,
      interval: 50
    )

    {:ok, registry_pid} = PoolRegistry.get_worker_pid(worker_id)
    assert registry_pid == worker_pid
    {:ok, starter_pid} = StarterRegistry.get_starter_pid(worker_id)

    {starter_pid, registry_pid}
  end

  defp assert_worker_shutdown(worker_id, worker_pid) do
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert_eventually(fn ->
      match?({:error, :not_found}, PoolRegistry.get_worker_pid(worker_id))
    end)

    assert_eventually(fn -> not StarterRegistry.starter_exists?(worker_id) end)
  end

  defp unique_worker_id do
    "worker_supervisor_test_#{System.unique_integer([:positive])}"
  end

  defp bind_port!(port), do: do_bind_port(port, 20)

  defp do_bind_port(_port, 0), do: flunk("failed to bind to test port")

  defp do_bind_port(port, attempts) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        socket

      {:error, :eaddrinuse} ->
        receive do
        after
          10 -> :ok
        end

        do_bind_port(port, attempts - 1)

      {:error, reason} ->
        flunk("failed to bind port #{port}: #{inspect(reason)}")
    end
  end

  defp configure_pooling do
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 1})

    Application.put_env(:snakepit, :pools, [
      %{
        name: :default,
        worker_profile: :process,
        pool_size: 1,
        adapter_module: MockGRPCAdapter
      }
    ])

    Application.put_env(:snakepit, :adapter_module, MockGRPCAdapter)
  end

  defp capture_env do
    %{
      pooling_enabled: Application.get_env(:snakepit, :pooling_enabled),
      pools: Application.get_env(:snakepit, :pools),
      pool_config: Application.get_env(:snakepit, :pool_config),
      adapter_module: Application.get_env(:snakepit, :adapter_module)
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> Application.delete_env(:snakepit, key)
      {key, value} -> Application.put_env(:snakepit, key, value)
    end)
  end
end
