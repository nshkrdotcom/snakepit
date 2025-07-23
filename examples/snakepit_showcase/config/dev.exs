import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :snakepit_showcase,
  debug: true

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :logger, :default_handler,
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]