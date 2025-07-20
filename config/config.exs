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

  # Wire protocol configuration
  # Options: :auto (negotiate), :msgpack, :json
  wire_protocol: :auto,

  # Worker configuration
  worker_init_timeout: 20_000,
  worker_health_check_interval: 30_000,
  worker_shutdown_grace_period: 2_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
