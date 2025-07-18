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

    children =
      if pooling_enabled do
        pool_config = Application.get_env(:snakepit, :pool_config, %{})
        pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)

        Logger.info("🚀 Starting Snakepit with pooling enabled (size: #{pool_size})")

        [
          # Task supervisor for async pool operations
          {Task.Supervisor, name: Snakepit.TaskSupervisor},

          # Session store for session management
          Snakepit.Bridge.SessionStore,

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
        Logger.info("🔧 Starting Snakepit with pooling disabled")
        []
      end

    opts = [strategy: :one_for_one, name: Snakepit.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
