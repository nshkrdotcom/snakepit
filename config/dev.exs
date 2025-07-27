import Config

# Development configuration
# In development, we typically want more verbose logging
config :logger, level: :debug

# Configure Snakepit for development
config :snakepit,
  # Use the mock adapter for development testing
  # The real adapter (SnakepitGRPCBridge.Adapter) is in the bridge layer
  adapter_module: Snakepit.TestAdapters.MockAdapter
