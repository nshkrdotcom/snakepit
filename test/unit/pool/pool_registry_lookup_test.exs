defmodule Snakepit.Pool.RegistryLookupTest do
  use ExUnit.Case, async: true

  import Snakepit.TestHelpers, only: [assert_eventually: 2]

  alias Snakepit.Pool
  alias Snakepit.Pool.Registry, as: PoolRegistry

  setup do
    case start_supervised(PoolRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "extract_pool_name_from_worker_id prefers registry metadata" do
    worker_id = "custom-grpc-worker-#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn(fn ->
        Registry.register(
          PoolRegistry,
          worker_id,
          %{worker_module: Snakepit.GRPCWorker, pool_name: :analytics}
        )

        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1_000
    result = Pool.extract_pool_name_from_worker_id(worker_id)
    assert :analytics == result
    send(pid, :stop)
  end

  test "falls back to default and logs when metadata missing" do
    worker_id = "unparseable-worker-id"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :default == Pool.extract_pool_name_from_worker_id(worker_id)
      end)

    assert log =~ "Falling back to worker_id parsing"
    assert log =~ worker_id
  end

  defmodule PoolStub do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:worker_ready, worker_id}, _from, test_pid) do
      send(test_pid, {:worker_ready, worker_id})
      {:reply, :ok, test_pid}
    end
  end

  describe "GRPC worker registration" do
    setup %{test: test_name} do
      ensure_started(Snakepit.Pool.ProcessRegistry)
      {:ok, pool_pid} = start_supervised({PoolStub, self()})

      script_path =
        Path.join([__DIR__, "..", "..", "support", "mock_grpc_server_ephemeral.sh"])

      File.chmod!(script_path, 0o755)

      worker_id = "registry_meta_#{test_name}_#{System.unique_integer([:positive])}"

      {:ok, worker} =
        Snakepit.GRPCWorker.start_link(
          id: worker_id,
          adapter: Snakepit.TestAdapters.EphemeralPortGRPCAdapter,
          pool_name: pool_pid,
          pool_identifier: :analytics_pool,
          worker_config: %{
            heartbeat: %{enabled: false}
          }
        )

      on_exit(fn ->
        if Process.alive?(worker) do
          try do
            GenServer.stop(worker, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, worker_id: worker_id, worker: worker, pool: pool_pid}
    end

    test "stores metadata for registry lookups", %{worker_id: worker_id, pool: pool_pid} do
      assert_eventually(fn -> match?({:ok, _}, PoolRegistry.get_worker_pid(worker_id)) end,
        timeout: 5_000,
        interval: 25
      )

      [{pid, metadata}] = Registry.lookup(PoolRegistry, worker_id)

      assert is_pid(pid)
      assert metadata.worker_module == Snakepit.GRPCWorker
      assert metadata.pool_identifier == :analytics_pool

      assert Pool.extract_pool_name_from_worker_id(worker_id) == :analytics_pool

      assert {:ok, ^worker_id} = PoolRegistry.get_worker_id_by_pid(pid)

      assert {:ok, ^pid, metadata} = PoolRegistry.fetch_worker(worker_id)
      assert metadata.pool_name == pool_pid
    end
  end

  test "put_metadata returns error when worker is not registered" do
    assert {:error, :not_registered} =
             PoolRegistry.put_metadata("ghost-worker", %{worker_module: Snakepit.GRPCWorker})
  end

  defp ensure_started(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
