import Config

# Runtime configuration (loaded after code compilation)
if config_env() == :prod do
  config :snakepit_showcase,
    debug: false
end