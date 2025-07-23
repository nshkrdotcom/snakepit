import Config

# Runtime configuration can be set via environment variables
if config_env() == :prod do
  config :logger, level: :info
end