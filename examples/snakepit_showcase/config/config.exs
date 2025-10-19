import Config

config :snakepit_showcase,
  ecto_repos: []

# Snakepit configuration
config :snakepit,
  # Suppress Snakepit internal logs for clean demo output
  log_level: :warning,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 4,
    max_overflow: 2,
    strategy: :fifo,
    adapter_args: [
      "--adapter",
      "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"
    ]
  },
  grpc_config: %{
    base_port: 50051,
    port_range: 100,
    health_check_interval: 30_000
  }

# Configure telemetry
config :snakepit_showcase, :telemetry,
  metrics: true,
  logging: true

# Import environment specific config
import_config "#{config_env()}.exs"
