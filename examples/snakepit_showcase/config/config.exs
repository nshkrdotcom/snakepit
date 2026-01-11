import Config

snakepit_root = Path.expand("../../..", __DIR__)

python_executable_path = Path.join([snakepit_root, ".venv", "bin", "python3"])
python_executable = if File.exists?(python_executable_path), do: python_executable_path, else: nil

config :snakepit_showcase,
  ecto_repos: []

# Snakepit configuration
config :snakepit,
  # Suppress Snakepit internal logs for clean demo output
  log_level: :error,
  adapter_module: Snakepit.Adapters.GRPCPython,
  bootstrap_project_root: snakepit_root,
  pooling_enabled: true,
  pool_config: %{
    pool_size: 4,
    max_overflow: 2,
    strategy: :fifo,
    adapter_args: [
      "--adapter",
      "snakepit_bridge.adapters.showcase.showcase_adapter.ShowcaseAdapter"
    ]
  },
  grpc_listener: %{
    mode: :external,
    host: "localhost",
    port: 50051
  }

if python_executable do
  config :snakepit, :python_executable, python_executable
end

# Configure telemetry
config :snakepit_showcase, :telemetry,
  metrics: true,
  logging: true

# Import environment specific config
import_config "#{config_env()}.exs"
