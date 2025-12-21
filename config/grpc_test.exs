import Config

# Core Snakepit configuration
config :snakepit,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 2,
    max_workers: 10,
    startup_timeout: 10_000,
    worker_restart_delay: 1_000
  },
  adapter_module: Snakepit.Adapters.GRPCPython,
  grpc_port: 50051,
  grpc_host: "localhost",
  protocol_negotiation: true,
  enable_process_registry: true,
  enable_application_cleanup: true

# Logger configuration for development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :worker_id]

# Set a reasonable level for development
config :logger, level: :info
