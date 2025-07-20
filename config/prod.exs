import Config

# Production configuration
# Use MessagePack for optimal performance in production
config :snakepit,
  wire_protocol: :msgpack,

  # Configure the adapter module
  adapter_module: Snakepit.Adapters.GenericPythonV2

# Reduce logging in production
config :logger, level: :info
