import Config

snakepit_root = Path.expand("../../..", __DIR__)

python_executable_path = Path.join([snakepit_root, ".venv", "bin", "python3"])
python_executable = if File.exists?(python_executable_path), do: python_executable_path, else: nil

# Configure Snakepit for load testing
config :snakepit,
  adapter_module: Snakepit.Adapters.GRPCPython,
  bootstrap_project_root: snakepit_root,
  pooling_enabled: true,
  grpc_port: 50051,
  grpc_host: "localhost",
  # 60 seconds for load testing
  grpc_timeout: 60_000,
  # Slightly less than gRPC timeout
  python_timeout: 55_000,
  pool_config: %{
    # Start with smaller pool to avoid eagain errors
    pool_size: 10,
    adapter_args: [
      "--adapter",
      "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"
    ]
  }

if python_executable do
  config :snakepit, :python_executable, python_executable
end

# Configure logger for load testing
config :logger,
  level: :info,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"
