# This file is responsible for configuring Snakepit
import Config

# Configure Logger metadata
config :logger, :console,
  metadata: [
    :request_id,
    :worker_id,
    :pool_name,
    :event_parts,
    :reason,
    :status,
    :headers,
    :enabled,
    :rate,
    :patterns,
    :channel_type
  ]

# Default configuration for Snakepit
config :snakepit,
  # Logging level for Snakepit internal logs
  # Options: :debug, :info, :warning, :error, :none
  # Set to :warning or :none for clean output in production
  log_level: :info,
  # Track current Mix environment for runtime diagnostics without depending on Mix at runtime
  environment: config_env(),
  # Pooling is opt-in to avoid auto-start surprises in scripts and examples
  pooling_enabled: false,
  enable_otlp?: false,

  # Pool configuration
  pool_config: %{
    pool_size: System.schedulers_online() * 2,
    # SAFETY LIMIT: Maximum workers to prevent system resource exhaustion
    # 200+ workers need careful tuning of batch size and delays
    # Safe limit is around 150-200 depending on system resources
    max_workers: 1000,
    # Concurrent worker startup batch size (prevents fork bomb)
    # Spawning too many workers simultaneously causes {:eagain} errors
    # CRITICAL: Batch size must be small enough to avoid resource exhaustion
    # Each Python process consumes ~50MB RAM + file descriptors + kernel overhead
    # For 200+ workers, use smaller batches (5-8) to prevent connection queue saturation
    startup_batch_size: 8,
    # Delay between batches in milliseconds
    # CRITICAL: Longer delays prevent system overload during startup
    # For 200+ workers, use 750ms+ to let the Elixir gRPC server catch up
    startup_batch_delay_ms: 750
  },

  # Global heartbeat defaults (per-worker overrides inherit from this map)
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 2_000,
    timeout_ms: 10_000,
    max_missed_heartbeats: 3,
    initial_delay_ms: 0,
    dependent: true
  },
  telemetry_metrics: %{
    prometheus: %{
      enabled: false,
      port: 9568,
      name: :snakepit_prometheus_metrics
    }
  },
  opentelemetry: %{
    enabled: false,
    exporters: %{
      otlp: %{
        enabled: false,
        endpoint: "http://localhost:4318",
        protocol: :http_protobuf,
        headers: []
      },
      console: %{
        enabled: false
      }
    },
    resource: %{
      service_name: "snakepit",
      service_namespace: "snakepit"
    }
  },

  # Worker configuration
  worker_init_timeout: 20_000,
  worker_health_check_interval: 30_000,
  worker_shutdown_grace_period: 2_000,

  # gRPC configuration
  # Port for the central Elixir gRPC server (source of truth for state)
  grpc_port: 50051,

  # Host for the central Elixir gRPC server
  # This is used by Python workers to callback to Elixir
  # Can be overridden for distributed deployments (Docker, K8s, etc.)
  grpc_host: "localhost",

  # Worker ports are OS-assigned (ephemeral); no range configuration required.

  # Python scientific library threading limits
  # These are applied in Application.start/2 to prevent fork bombs during concurrent worker startup
  # When spawning many workers simultaneously, each tries to create threads from multiple libraries
  # (default: 24 threads per worker × 250 workers = 6,000 threads → "Cannot fork" errors)
  # Setting to 1 is optimal since parallelism happens at the worker pool level, not per-worker
  python_thread_limits: %{
    # OpenBLAS (numpy/scipy)
    openblas: 1,
    # OpenMP
    omp: 1,
    # Intel MKL
    mkl: 1,
    # NumExpr
    numexpr: 1,
    # gRPC polling threads (default: number of CPU cores)
    grpc_poll_threads: 1
  }

enable_otlp_env =
  System.get_env("SNAKEPIT_ENABLE_OTLP", "false")
  |> String.downcase()
  |> Kernel.==("true")

config :snakepit, :enable_otlp?, enable_otlp_env

if enable_otlp_env do
  endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

  console_enabled =
    System.get_env("SNAKEPIT_OTEL_CONSOLE", "false")
    |> String.downcase()
    |> (&(&1 in ["1", "true", "yes", "on"])).()

  config :snakepit, :opentelemetry,
    enabled: true,
    exporters: %{
      otlp: %{
        enabled: true,
        endpoint: endpoint,
        protocol: System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL", "http_protobuf")
      },
      console: %{
        enabled: console_enabled
      }
    }
else
  config :snakepit, :opentelemetry,
    enabled: false,
    exporters: %{
      otlp: %{enabled: false},
      console: %{enabled: false}
    }

  config :opentelemetry, :tracer, :none
  config :opentelemetry, :meter, :none
  config :opentelemetry, :processors, []
  config :opentelemetry_exporter, :resource, []
end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
