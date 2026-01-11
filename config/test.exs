import Config

test_partition = System.get_env("MIX_TEST_PARTITION") || "1"
test_instance = System.get_env("SNAKEPIT_INSTANCE_NAME") || "snakepit_test_#{test_partition}"

# Test configuration
config :snakepit,
  instance_name: test_instance,
  # Disable pooling by default so unit tests do not spawn Python workers.
  # Integration tests explicitly enable pooling in their setup blocks.
  pooling_enabled: false,
  env_doctor_module: Snakepit.Test.FakeDoctor,

  # Use smaller pool size for tests
  pool_config: %{
    pool_size: 2
  },

  # Configure the adapter module
  adapter_module: Snakepit.Adapters.GRPCPython,

  # Configure test environment for gRPC bridge
  test_mode: true

config :snakepit, :opentelemetry, skip_runtime?: true

# Configure Logger for tests
# Set to :warning to hide debug and info logs during tests
# You can set to :debug if you need to see all logs while debugging
config :logger, level: :warning

# Configure ExUnit
config :ex_unit,
  capture_log: true,
  # Exclude performance tests by default
  exclude: [:performance]
