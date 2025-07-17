defmodule Snakepit.Application do
  @moduledoc """
  Application supervisor for Snakepit pooler.

  Starts the core infrastructure:
  - Registry for worker process registration
  - ProcessRegistry for Python PID tracking
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
          # Registry for worker process registration
          Snakepit.Pool.Registry,

          # Process registry for Python PID tracking
          Snakepit.Pool.ProcessRegistry,

          # Session store for session management
          Snakepit.Bridge.SessionStore,

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
