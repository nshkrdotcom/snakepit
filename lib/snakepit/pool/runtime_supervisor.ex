defmodule Snakepit.Pool.RuntimeSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size)

    children = [
      Snakepit.GRPC.ClientSupervisor,
      Snakepit.GRPC.Listener,
      Snakepit.Pool.Worker.StarterRegistry,
      Snakepit.WorkerProfile.Thread.CapacityStore,
      Snakepit.Pool.WorkerSupervisor,
      Snakepit.Worker.LifecycleManager,
      {Snakepit.Pool, [size: pool_size]},
      Snakepit.Telemetry.GrpcStream
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
