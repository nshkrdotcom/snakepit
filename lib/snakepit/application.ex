defmodule Snakepit.Application do
  @moduledoc """
  Application supervisor for Snakepit pooler.

  Starts the core infrastructure:
  - Registry for worker process registration
  - StarterRegistry for worker starter supervisors
  - ProcessRegistry for external PID tracking
  - SessionStore for session management
  - WorkerSupervisor for managing worker processes
  - Pool manager for request distribution
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Check if pooling is enabled (default: false to prevent auto-start issues)
    pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, false)

    IO.inspect(
      pooling_enabled: pooling_enabled,
      env: Mix.env(),
      label: "Snakepit.Application.start/2"
    )

    # Get gRPC config for the Elixir server
    grpc_port = Application.get_env(:snakepit, :grpc_port, 50051)

    # Always start SessionStore as it's needed for tests and bridge functionality
    base_children = [
      Snakepit.Bridge.SessionStore,
      Snakepit.Bridge.ToolRegistry
    ]

    pool_children =
      if pooling_enabled do
        pool_config = Application.get_env(:snakepit, :pool_config, %{})
        pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)

        Logger.info("🚀 Starting Snakepit with pooling enabled (size: #{pool_size})")

        [
          # Start the central gRPC server that manages state
          {GRPC.Server.Supervisor,
           endpoint: Snakepit.GRPC.Endpoint, port: grpc_port, start_server: true}
          |> tap(fn spec ->
            IO.inspect(spec, label: "Adding GRPC.Server.Supervisor to children")
          end),

          # Task supervisor for async pool operations
          {Task.Supervisor, name: Snakepit.TaskSupervisor},

          # Registry for worker process registration
          Snakepit.Pool.Registry,

          # Registry for worker starter supervisors
          Snakepit.Pool.Worker.StarterRegistry,

          # Process registry for PID tracking
          Snakepit.Pool.ProcessRegistry,

          # Worker supervisor for managing worker processes
          Snakepit.Pool.WorkerSupervisor,

          # Main pool manager
          {Snakepit.Pool, [size: pool_size]},

          # Application cleanup for hard process termination guarantees
          # MUST BE LAST - terminates FIRST to ensure workers have shut down
          Snakepit.Pool.ApplicationCleanup
        ]
      else
        Logger.info("🔧 Starting Snakepit with pooling disabled")
        []
      end

    children = base_children ++ pool_children

    opts = [strategy: :one_for_one, name: Snakepit.Supervisor]
    result = Supervisor.start_link(children, opts)
    IO.inspect(System.monotonic_time(:millisecond), label: "Snakepit.Application started at")
    result
  end

  def stop(_state) do
    IO.inspect(System.monotonic_time(:millisecond),
      label: "Snakepit.Application.stop/1 called at"
    )

    :ok
  end
end
