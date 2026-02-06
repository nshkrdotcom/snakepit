defmodule Snakepit.Pool.RuntimeSupervisorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool.RuntimeSupervisor

  defmodule CrashableChild do
    use GenServer

    def start_link({name, parent}) do
      GenServer.start_link(__MODULE__, {name, parent})
    end

    @impl true
    def init({name, parent}) do
      send(parent, {:child_started, name, self()})
      {:ok, %{name: name, parent: parent}}
    end
  end

  defmodule RestForOneBlastRadiusHarness do
    use Supervisor

    def start_link(parent) do
      Supervisor.start_link(__MODULE__, parent)
    end

    @impl true
    def init(parent) do
      children = [
        %{
          id: :core,
          start: {CrashableChild, :start_link, [{:core, parent}]},
          restart: :permanent,
          shutdown: 500,
          type: :worker
        },
        %{
          id: :pool,
          start: {CrashableChild, :start_link, [{:pool, parent}]},
          restart: :permanent,
          shutdown: 500,
          type: :worker
        },
        %{
          id: :telemetry,
          start: {CrashableChild, :start_link, [{:telemetry, parent}]},
          restart: :permanent,
          shutdown: 500,
          type: :worker
        }
      ]

      Supervisor.init(children, strategy: :rest_for_one)
    end
  end

  test "uses rest_for_one strategy with ordered dependent children" do
    assert {:ok, {flags, child_specs}} = RuntimeSupervisor.init(pool_size: 3)

    assert flags.strategy == :rest_for_one

    child_ids = Enum.map(child_specs, & &1.id)

    assert child_ids == [
             Snakepit.GRPC.ClientSupervisor,
             Snakepit.GRPC.Listener,
             Snakepit.Pool.Worker.StarterRegistry,
             Snakepit.WorkerProfile.Thread.CapacityStore,
             Snakepit.Pool.WorkerSupervisor,
             Snakepit.Worker.LifecycleManager,
             Snakepit.Pool,
             Snakepit.Telemetry.GrpcStream
           ]
  end

  test "rest_for_one blast radius does not restart pool when last telemetry child crashes" do
    {:ok, sup} = start_supervised({RestForOneBlastRadiusHarness, self()})

    assert_receive {:child_started, :core, _core_pid}, 500
    assert_receive {:child_started, :pool, pool_pid}, 500
    assert_receive {:child_started, :telemetry, telemetry_pid}, 500

    Process.exit(telemetry_pid, :kill)

    assert_receive {:child_started, :telemetry, restarted_telemetry_pid}, 1_000
    assert restarted_telemetry_pid != telemetry_pid
    assert Process.alive?(pool_pid)

    children = Supervisor.which_children(sup)

    {_id, current_pool_pid, _type, _mods} =
      Enum.find(children, fn {id, _, _, _} -> id == :pool end)

    assert current_pool_pid == pool_pid
  end
end
