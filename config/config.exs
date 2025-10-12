# This file is responsible for configuring Snakepit
import Config

# Default configuration for Snakepit
config :snakepit,
  # Enable pooling by default
  pooling_enabled: true,

  # Pool configuration
  pool_config: %{
    pool_size: System.schedulers_online() * 2
  },

  # Worker configuration
  worker_init_timeout: 20_000,
  worker_health_check_interval: 30_000,
  worker_shutdown_grace_period: 2_000,

  # gRPC configuration
  # Port for the central Elixir gRPC server (source of truth for state)
  grpc_port: 50051,

  # Host for the central Elixir gRPC server
  # This is used by Python workers to callback to Elixir
  # Can be overridden for distributed deployments (Docker, K8s, etc.)
  grpc_host: "localhost",

  # gRPC worker configuration
  grpc_config: %{
    base_port: 50052,
    port_range: 175
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
