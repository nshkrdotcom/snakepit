import Config

snakepit_verbose =
  System.get_env("SNAKEPIT_VERBOSE", "0")
  |> String.downcase()
  |> case do
    value when value in ["1", "true", "yes", "on"] -> true
    _ -> false
  end

# Development configuration
# Suppress logs by default for cleaner output
# Change to :debug for detailed troubleshooting
config :logger,
  level: if(snakepit_verbose, do: :info, else: :warning),
  # Suppress gRPC interceptor logs (Handled by, Response :ok, etc.)
  compile_time_purge_matching: [
    [application: :grpc, level_lower_than: :error]
  ]

# Configure Snakepit for development
config :snakepit,
  # Use the gRPC Python adapter
  adapter_module: Snakepit.Adapters.GRPCPython,
  # Suppress Snakepit internal logs unless verbose requested
  log_level: if(snakepit_verbose, do: :info, else: :warning),
  dev_logfanout?: snakepit_verbose
