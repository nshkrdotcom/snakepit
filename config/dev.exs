import Config

# Development configuration
# Suppress logs by default for cleaner output
# Change to :debug for detailed troubleshooting
config :logger,
  level: :warning,
  # Suppress gRPC interceptor logs (Handled by, Response :ok, etc.)
  compile_time_purge_matching: [
    [application: :grpc, level_lower_than: :error]
  ]

# Configure Snakepit for development
config :snakepit,
  # Use the gRPC Python adapter
  adapter_module: Snakepit.Adapters.GRPCPython,
  # Suppress Snakepit internal logs
  log_level: :warning
