import Config

# Configure Snakepit with a small pool for testing
config :snakepit,
  pool_config: %{
    pool_size: 5,
    max_overflow: 10
  }