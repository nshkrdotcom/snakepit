import Config

# Test configuration
config :logger, level: :warning

config :snakepit,
  pool_config: %{
    pool_size: 2,
    max_overflow: 2
  }