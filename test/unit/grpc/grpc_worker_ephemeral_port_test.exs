defmodule Snakepit.GRPCWorkerEphemeralPortTest do
  use Snakepit.TestCase, async: false

  alias Snakepit.GRPCWorker

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

    script_path =
      Path.join([__DIR__, "..", "..", "support", "mock_grpc_server_ephemeral.sh"])

    # Ensure the mock server script is executable for the spawned Port
    File.chmod!(script_path, 0o755)

    {:ok, pool: pool_pid}
  end

  test "stores the actual GRPC_READY port discovered at runtime", %{pool: pool_pid} do
    worker_id = "ephemeral_port_worker_#{System.unique_integer([:positive])}"

    {:ok, worker} =
      GRPCWorker.start_link(
        id: worker_id,
        adapter: Snakepit.TestAdapters.EphemeralPortGRPCAdapter,
        pool_name: pool_pid,
        worker_config: %{
          heartbeat: %{
            enabled: false
          }
        }
      )

    expected_port = Snakepit.TestAdapters.EphemeralPortGRPCAdapter.actual_port()

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

  defp ensure_started(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
