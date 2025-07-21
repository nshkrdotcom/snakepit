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
  health_check_interval: 30_000,
  protocol_negotiation: true,
  enable_process_registry: true,
  enable_application_cleanup: true,
  grpc_config: %{
    base_port: 50051,
    port_range: 10
  }

# Logger configuration for development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :worker_id]

# Set a reasonable level for development
config :logger, level: :info
