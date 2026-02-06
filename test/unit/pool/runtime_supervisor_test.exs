defmodule Snakepit.Pool.RuntimeSupervisorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Pool.RuntimeSupervisor

  test "uses rest_for_one strategy with ordered dependent children" do
    assert {:ok, {flags, child_specs}} = RuntimeSupervisor.init(pool_size: 3)

    assert flags.strategy == :rest_for_one

    child_ids = Enum.map(child_specs, & &1.id)

    assert child_ids == [
             Snakepit.GRPC.ClientSupervisor,
             Snakepit.GRPC.Listener,
             Snakepit.Telemetry.GrpcStream,
             Snakepit.Pool.Worker.StarterRegistry,
             Snakepit.WorkerProfile.Thread.CapacityStore,
             Snakepit.Pool.WorkerSupervisor,
             Snakepit.Worker.LifecycleManager,
             Snakepit.Pool
           ]
  end
end
