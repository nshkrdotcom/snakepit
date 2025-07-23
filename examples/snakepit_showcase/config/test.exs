import Config

# Configure for test environment
config :snakepit_showcase,
  debug: false

# Print only warnings and errors during test
config :logger, level: :warning