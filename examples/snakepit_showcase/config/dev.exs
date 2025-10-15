import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :snakepit_showcase,
  debug: true

# Suppress all logs by default for clean demo output
# Change to :debug for detailed troubleshooting
config :logger,
  level: :warning,
  # Suppress gRPC interceptor logs
  compile_time_purge_matching: [
    [application: :grpc, level_lower_than: :error]
  ]

config :logger, :default_handler,
  level: :warning,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]