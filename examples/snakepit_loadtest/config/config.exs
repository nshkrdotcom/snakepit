import Config

# Configure Snakepit for load testing
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  pooling_enabled: true,
  grpc_port: 50051,
  grpc_host: "localhost",
  grpc_timeout: 60_000,  # 60 seconds for load testing
  python_timeout: 55_000,  # Slightly less than gRPC timeout
  # Use the ShowcaseAdapter which has the required tools
  python_adapter: "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter",
  pool_config: %{
    pool_size: 10,  # Start with smaller pool to avoid eagain errors
    adapter_args: ["--adapter", "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"]
  }

# Configure logger for load testing
config :logger,
  level: :info,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"