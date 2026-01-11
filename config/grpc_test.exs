import Config

# Core Snakepit configuration
config :snakepit,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 2,
    max_workers: 10
  },
  adapter_module: Snakepit.Adapters.GRPCPython,
  grpc_listener: %{
    mode: :external,
    host: "localhost",
    port: 50051
  }

# Logger configuration for development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :worker_id]

# Set a reasonable level for development
config :logger, level: :info
