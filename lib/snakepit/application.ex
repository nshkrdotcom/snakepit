defmodule Snakepit.Application do
  @moduledoc """
  Pure infrastructure application supervisor for Snakepit core.

  Starts only the core pooling and session infrastructure:
  - Registry for worker process registration
  - StarterRegistry for worker starter supervisors  
  - ProcessRegistry for external PID tracking
  - WorkerSupervisor for managing worker processes
  - Pool manager for request distribution
  - Telemetry infrastructure

  Bridge-specific functionality (SessionStore, ToolRegistry, gRPC) is handled
  by bridge packages that depend on Snakepit core.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Check if pooling is enabled (default: true for core infrastructure)
    pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, true)

    # Base infrastructure (always started)
    base_children = [
      # Telemetry infrastructure
      {Task, fn -> Snakepit.Telemetry.attach_handlers() end}
    ]

    pool_children =
      if pooling_enabled do
        pool_config = Application.get_env(:snakepit, :pool_config, %{})
        pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)

        Logger.info("🚀 Starting Snakepit core infrastructure (pool size: #{pool_size})")

        [
          # Task supervisor for async pool operations
          {Task.Supervisor, name: Snakepit.TaskSupervisor},

          # Registry for worker process registration
          Snakepit.Pool.Registry,

          # Registry for worker starter supervisors
          Snakepit.Pool.Worker.StarterRegistry,

          # Process registry for PID tracking
          Snakepit.Pool.ProcessRegistry,

          # Application cleanup for hard process termination guarantees
          Snakepit.Pool.ApplicationCleanup,

          # Worker supervisor for managing worker processes
          Snakepit.Pool.WorkerSupervisor,

          # Main pool manager
          {Snakepit.Pool, [size: pool_size]}
        ]
      else
        Logger.info("🔧 Starting Snakepit with pooling disabled (testing mode)")
        []
      end

    children = base_children ++ pool_children

    opts = [strategy: :one_for_one, name: Snakepit.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("✅ Snakepit core infrastructure started successfully")
        {:ok, pid}
        
      {:error, reason} ->
        Logger.error("❌ Failed to start Snakepit core infrastructure: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  @impl true
  def stop(_state) do
    Logger.info("🛑 Stopping Snakepit core infrastructure")
    Snakepit.Telemetry.detach_handlers()
    :ok
  end
end
