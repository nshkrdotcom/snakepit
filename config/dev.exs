import Config

# Development configuration
# In development, we typically want more verbose logging
config :logger, level: :debug

# Configure Snakepit for development
config :snakepit,
  # Use the generic Python adapter
  adapter_module: Snakepit.Adapters.GenericPythonV2
