defmodule Snakepit.Application do
  @moduledoc """
  Application supervisor for Snakepit pooler.

  Starts the core infrastructure:
  - Registry for worker process registration
  - StarterRegistry for worker starter supervisors
  - ProcessRegistry for external PID tracking
  - SessionStore for session management
  - WorkerSupervisor for managing worker processes
  - Pool manager for request distribution
  """

  use Application
  require Logger
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonThreadLimits
  alias Snakepit.Telemetry.OpenTelemetry

  @runtime_env Application.compile_env(:snakepit, :environment, :prod)

  @impl true
  def start(_type, _args) do
    configure_logging()

    # Configure threading limits for Python scientific libraries and gRPC
    # This prevents fork bombs when spawning many workers concurrently
    # Each Python worker tries to spawn threads from multiple sources:
    # - OpenBLAS: 24 threads (numpy/scipy)
    # - gRPC: CPU cores threads (grpcio polling)
    # - Other libraries (absl, protobuf, etc.)
    # With 250 workers, this can create 6,000+ threads causing "Cannot fork" errors
    thread_limits =
      :snakepit
      |> Application.get_env(:python_thread_limits)
      |> PythonThreadLimits.resolve()

    # Scientific computing libraries
    System.put_env("OPENBLAS_NUM_THREADS", thread_limits[:openblas] |> to_string())
    System.put_env("OMP_NUM_THREADS", thread_limits[:omp] |> to_string())
    System.put_env("MKL_NUM_THREADS", thread_limits[:mkl] |> to_string())
    System.put_env("NUMEXPR_NUM_THREADS", thread_limits[:numexpr] |> to_string())

    # gRPC library threading
    # Use single-threaded polling
    System.put_env("GRPC_POLL_STRATEGY", "poll")
    # Reduce logging overhead
    System.put_env("GRPC_VERBOSITY", "ERROR")

    # Python threading behavior
    # Unbuffered output for better logging
    System.put_env("PYTHONUNBUFFERED", "1")

    SLog.info(
      :startup,
      "Set Python thread limits",
      openblas: thread_limits[:openblas],
      omp: thread_limits[:omp],
      mkl: thread_limits[:mkl],
      numexpr: thread_limits[:numexpr],
      grpc_poll_strategy: "poll"
    )

    # Check if pooling is enabled (default: false to prevent auto-start issues)
    pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, false)

    if pooling_enabled do
      ensure_python_ready()
    end

    if Application.get_env(:snakepit, :enable_otlp?, false) do
      SLog.info(:startup, "OTLP telemetry enabled", enabled: true)
      OpenTelemetry.setup()
    else
      SLog.debug(:startup, "OTLP telemetry disabled", enabled: false)
    end

    SLog.debug(
      :startup,
      "Snakepit.Application.start/2",
      pooling_enabled: pooling_enabled,
      environment: @runtime_env
    )

    # Get gRPC config for the Elixir server
    grpc_port = Defaults.grpc_port()

    # Always start SessionStore as it's needed for tests and bridge functionality
    telemetry_children = Snakepit.TelemetryMetrics.reporter_children()

    base_children = [
      Snakepit.Bridge.SessionStore,
      Snakepit.Bridge.ToolRegistry,
      # Process registry for PID tracking (always available for cleanup)
      Snakepit.Pool.ProcessRegistry,
      # Application cleanup for hard process termination guarantees
      # Runs after pool children terminate to catch any stragglers
      Snakepit.Pool.ApplicationCleanup
    ]

    pool_children =
      if pooling_enabled do
        pool_config = Application.get_env(:snakepit, :pool_config, %{})
        pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)

        SLog.info(:startup, "Starting Snakepit with pooling enabled", pool_size: pool_size)

        [
          # GRPC client supervisor - required for connecting to Python workers
          # Must be started before any gRPC client connections are attempted
          {GRPC.Client.Supervisor, []},

          # Start the central gRPC server that manages state
          # DIAGNOSTIC: Increase backlog to handle high concurrent connection load (200+ workers)
          # Default Cowboy backlog is ~128, which causes connection refusals during startup
          {GRPC.Server.Supervisor,
           endpoint: Snakepit.GRPC.Endpoint,
           port: grpc_port,
           start_server: true,
           adapter_opts: [
             num_acceptors: Defaults.grpc_num_acceptors(),
             max_connections: Defaults.grpc_max_connections(),
             socket_opts: [backlog: Defaults.grpc_socket_backlog()]
           ]},

          # Task supervisor for async pool operations
          {Task.Supervisor, name: Snakepit.TaskSupervisor},

          # Telemetry gRPC stream manager (for Python worker telemetry)
          Snakepit.Telemetry.GrpcStream,

          # Registry for worker process registration
          Snakepit.Pool.Registry,

          # Registry for worker starter supervisors
          Snakepit.Pool.Worker.StarterRegistry,

          # Thread profile capacity tracking
          Snakepit.WorkerProfile.Thread.CapacityStore,

          # Worker supervisor for managing worker processes
          Snakepit.Pool.WorkerSupervisor,

          # Worker lifecycle manager for automatic recycling
          Snakepit.Worker.LifecycleManager,

          # Main pool manager
          {Snakepit.Pool, [size: pool_size]}
        ]
      else
        SLog.info(:startup, "Starting Snakepit with pooling disabled", pooling_enabled: false)
        []
      end

    children = telemetry_children ++ base_children ++ pool_children

    opts = [strategy: :one_for_one, name: Snakepit.Supervisor]
    result = Supervisor.start_link(children, opts)

    SLog.debug(:startup, "Snakepit.Application started",
      started_at_ms: System.monotonic_time(:millisecond)
    )

    result
  end

  @impl true
  def stop(_state) do
    SLog.debug(:shutdown, "Snakepit.Application.stop/1",
      stopped_at_ms: System.monotonic_time(:millisecond)
    )

    maybe_cleanup_on_stop()
    :ok
  end

  defp maybe_cleanup_on_stop do
    if Application.get_env(:snakepit, :cleanup_on_stop, true) do
      if Process.whereis(Snakepit.Pool.ProcessRegistry) do
        timeout_ms = Defaults.cleanup_on_stop_timeout_ms()
        poll_interval_ms = Defaults.cleanup_poll_interval_ms()

        try do
          Snakepit.RuntimeCleanup.cleanup_current_run(
            timeout_ms: timeout_ms,
            poll_interval_ms: poll_interval_ms
          )
        rescue
          error ->
            SLog.warning(:shutdown, "Shutdown cleanup failed", error: error)
        catch
          :exit, reason ->
            SLog.warning(:shutdown, "Shutdown cleanup exited", reason: reason)
        end
      end
    end
  end

  defp ensure_python_ready do
    doctor = Application.get_env(:snakepit, :env_doctor_module, Snakepit.EnvDoctor)
    doctor.ensure_python!()
  rescue
    error ->
      reraise error, __STACKTRACE__
  end

  defp configure_logging do
    grpc_level =
      Application.get_env(
        :snakepit,
        :grpc_log_level,
        default_grpc_log_level()
      )

    if grpc_level do
      Logger.put_application_level(:grpc, grpc_level)
    end
  end

  defp default_grpc_log_level do
    if Application.get_env(:snakepit, :library_mode, true) do
      :error
    else
      nil
    end
  end
end
