defmodule Snakepit.GRPCWorkerEphemeralPortTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.GRPCWorker
  alias Snakepit.TestAdapters.EphemeralPortGRPCAdapter

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

  defmodule BlockingPoolStub do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid), do: {:ok, %{test_pid: test_pid}}

    @impl true
    def handle_call({:worker_ready, worker_id}, _from, state) do
      send(state.test_pid, {:worker_ready_called, worker_id, self()})

      receive do
        :unblock -> :ok
      end

      {:reply, :ok, state}
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    ensure_started(Snakepit.Pool.Registry)
    ensure_started(Snakepit.Pool.ProcessRegistry)
    {:ok, pool_pid} = start_supervised(PoolStub)

    script_path =
      Path.join([__DIR__, "..", "..", "support", "mock_grpc_server_ephemeral.sh"])

    # Ensure the mock server script is executable for the spawned Port
    File.chmod!(script_path, 0o755)

    {:ok, pool: pool_pid}
  end

  test "stores the actual readiness port discovered at runtime", %{pool: pool_pid} do
    worker_id = "ephemeral_port_worker_#{System.unique_integer([:positive])}"

    {:ok, worker} =
      GRPCWorker.start_link(
        id: worker_id,
        adapter: EphemeralPortGRPCAdapter,
        pool_name: pool_pid,
        elixir_address: "localhost:0",
        worker_config: %{
          heartbeat: %{
            enabled: false
          }
        }
      )

    expected_port = EphemeralPortGRPCAdapter.actual_port()

    assert_eventually(
      fn ->
        case GenServer.call(worker, :get_port, 1_000) do
          {:ok, ^expected_port} -> true
          _ -> false
        end
      end,
      timeout: 5_000,
      interval: 25
    )

    :ok = GenServer.stop(worker)
  end

  test "shuts down gracefully if pool terminates during startup handshake" do
    worker_id = "pool_shutdown_race_#{System.unique_integer([:positive])}"

    {:ok, pool_pid} = start_supervised({BlockingPoolStub, self()})

    {:ok, worker} =
      GRPCWorker.start_link(
        id: worker_id,
        adapter: EphemeralPortGRPCAdapter,
        pool_name: pool_pid,
        elixir_address: "localhost:0",
        worker_config: %{
          heartbeat: %{enabled: false}
        }
      )

    worker_ref = Process.monitor(worker)

    assert_receive {:worker_ready_called, ^worker_id, ^pool_pid}, 5_000

    Process.exit(pool_pid, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, 5_000
    refute Process.alive?(worker)
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
