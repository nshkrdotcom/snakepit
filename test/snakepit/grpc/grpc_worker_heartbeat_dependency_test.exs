defmodule Snakepit.GRPCWorkerHeartbeatDependencyTest do
  @moduledoc """
  Verifies that GRPCWorker honors heartbeat dependency settings without
  requiring the Python adapter.
  """
  use Snakepit.TestCase, async: false

  alias Snakepit.GRPCWorker

  defmodule TestPool do
    @moduledoc false
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, [])
    end

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call({:worker_ready, _worker_id}, _from, state) do
      {:reply, :ok, state}
    end
  end

  setup do
    pool_pid = start_supervised!(TestPool)
    previous_flag = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_flag) end)
    %{pool_pid: pool_pid}
  end

  test "dependent heartbeat kills the worker on repeated ping failures", %{pool_pid: pool_pid} do
    worker_id = "grpc_dep_#{System.unique_integer([:positive])}"

    case start_worker_catching_exit(fn ->
           GRPCWorker.start_link(
             id: worker_id,
             adapter: Snakepit.TestAdapters.MockGRPCAdapter,
             pool_name: pool_pid,
             elixir_address: "localhost:0",
             worker_config: %{
               heartbeat: %{
                 enabled: true,
                 ping_interval_ms: 10,
                 timeout_ms: 20,
                 max_missed_heartbeats: 1,
                 dependent: true,
                 initial_delay_ms: 20,
                 ping_fun: fail_after_first_ping()
               }
             }
           )
         end) do
      {:ok, worker_pid} ->
        worker_ref = Process.monitor(worker_pid)
        assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, reason}, 500
        assert normalize_shutdown_reason(reason) in [:ping_failed, :heartbeat_timeout]

      {:exit, {:shutdown, {:shutdown, reason}}} ->
        assert reason in [:ping_failed, :heartbeat_timeout]

      {:exit, {:shutdown, reason}} ->
        assert reason in [:ping_failed, :heartbeat_timeout]
    end
  end

  test "independent heartbeat keeps the worker alive on ping failures until stopped", %{
    pool_pid: pool_pid
  } do
    worker_id = "grpc_ind_#{System.unique_integer([:positive])}"

    {:ok, worker_pid} =
      GRPCWorker.start_link(
        id: worker_id,
        adapter: Snakepit.TestAdapters.MockGRPCAdapter,
        pool_name: pool_pid,
        elixir_address: "localhost:0",
        worker_config: %{
          heartbeat: %{
            enabled: true,
            ping_interval_ms: 10,
            timeout_ms: 20,
            max_missed_heartbeats: 1,
            dependent: false,
            initial_delay_ms: 20,
            ping_fun: fail_after_first_ping()
          }
        }
      )

    refute_receive {:DOWN, _ref, :process, ^worker_pid, _}, 200
    assert Process.alive?(worker_pid)

    :ok = GenServer.stop(worker_pid)
  end

  defp fail_after_first_ping do
    fn _timestamp ->
      case Process.get(:first_ping_seen) do
        nil ->
          Process.put(:first_ping_seen, true)
          :ok

        _ ->
          {:error, :simulated_failure}
      end
    end
  end

  defp start_worker_catching_exit(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, reason -> {:exit, reason}
  end

  defp normalize_shutdown_reason({:shutdown, {:shutdown, inner}}), do: inner
  defp normalize_shutdown_reason({:shutdown, inner}), do: inner
  defp normalize_shutdown_reason(inner), do: inner
end
