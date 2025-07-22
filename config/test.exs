import Config

# Test configuration
config :snakepit,
  # Use smaller pool size for tests
  pool_config: %{
    pool_size: 2
  },

  # Use JSON for tests to ensure compatibility
  wire_protocol: :json,

  # Shorter timeouts for tests
  worker_init_timeout: 5_000,
  worker_health_check_interval: 5_000,

  # Configure the adapter module
  adapter_module: Snakepit.Adapters.GenericPythonV2,

  # Configure test environment for gRPC bridge
  python_path: System.get_env("PYTHON_PATH", "python3"),
  grpc_timeout: 5_000,
  test_mode: true

# Configure Logger for tests
# Set to :warning to hide debug and info logs during tests
# You can set to :debug if you need to see all logs while debugging
config :logger, level: :warning

# Configure ExUnit
config :ex_unit,
  capture_log: true,
  exclude: [:performance]  # Exclude performance tests by default
