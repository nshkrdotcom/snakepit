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

  @impl true
  def start(_type, _args) do
    # Configure threading limits for Python scientific libraries and gRPC
    # This prevents fork bombs when spawning many workers concurrently
    # Each Python worker tries to spawn threads from multiple sources:
    # - OpenBLAS: 24 threads (numpy/scipy)
    # - gRPC: CPU cores threads (grpcio polling)
    # - Other libraries (absl, protobuf, etc.)
    # With 250 workers, this can create 6,000+ threads causing "Cannot fork" errors
    thread_limits =
      Application.get_env(:snakepit, :python_thread_limits, %{
        openblas: 1,
        omp: 1,
        mkl: 1,
        numexpr: 1,
        grpc_poll_threads: 1
      })

    # Scientific computing libraries
    System.put_env("OPENBLAS_NUM_THREADS", to_string(thread_limits.openblas))
    System.put_env("OMP_NUM_THREADS", to_string(thread_limits.omp))
    System.put_env("MKL_NUM_THREADS", to_string(thread_limits.mkl))
    System.put_env("NUMEXPR_NUM_THREADS", to_string(thread_limits.numexpr))

    # gRPC library threading
    # Use single-threaded polling
    System.put_env("GRPC_POLL_STRATEGY", "poll")
    # Reduce logging overhead
    System.put_env("GRPC_VERBOSITY", "ERROR")

    # Python threading behavior
    # Unbuffered output for better logging
    System.put_env("PYTHONUNBUFFERED", "1")

    Logger.info(
      "🧵 Set Python thread limits: OPENBLAS=#{thread_limits.openblas}, OMP=#{thread_limits.omp}, MKL=#{thread_limits.mkl}, NUMEXPR=#{thread_limits.numexpr}, GRPC=single-threaded"
    )

    # Check if pooling is enabled (default: false to prevent auto-start issues)
    pooling_enabled = Application.get_env(:snakepit, :pooling_enabled, false)

    IO.inspect(
      pooling_enabled: pooling_enabled,
      env: Mix.env(),
      label: "Snakepit.Application.start/2"
    )

    # Get gRPC config for the Elixir server
    grpc_port = Application.get_env(:snakepit, :grpc_port, 50051)

    # Always start SessionStore as it's needed for tests and bridge functionality
    base_children = [
      Snakepit.Bridge.SessionStore,
      Snakepit.Bridge.ToolRegistry
    ]

    pool_children =
      if pooling_enabled do
        pool_config = Application.get_env(:snakepit, :pool_config, %{})
        pool_size = Map.get(pool_config, :pool_size, System.schedulers_online() * 2)

        Logger.info("🚀 Starting Snakepit with pooling enabled (size: #{pool_size})")

        # Initialize ETS table for thread profile capacity tracking
        # Must be created before any workers start
        ensure_thread_capacity_table()

        [
          # Start the central gRPC server that manages state
          # DIAGNOSTIC: Increase backlog to handle high concurrent connection load (200+ workers)
          # Default Cowboy backlog is ~128, which causes connection refusals during startup
          {GRPC.Server.Supervisor,
           endpoint: Snakepit.GRPC.Endpoint,
           port: grpc_port,
           start_server: true,
           adapter_opts: [
             num_acceptors: 20,
             max_connections: 1000,
             socket_opts: [backlog: 512]
           ]}
          |> tap(fn spec ->
            IO.inspect(spec, label: "Adding GRPC.Server.Supervisor to children")
          end),

          # Task supervisor for async pool operations
          {Task.Supervisor, name: Snakepit.TaskSupervisor},

          # Registry for worker process registration
          Snakepit.Pool.Registry,

          # Registry for worker starter supervisors
          Snakepit.Pool.Worker.StarterRegistry,

          # Process registry for PID tracking
          Snakepit.Pool.ProcessRegistry,

          # Worker supervisor for managing worker processes
          Snakepit.Pool.WorkerSupervisor,

          # Worker lifecycle manager for automatic recycling
          Snakepit.Worker.LifecycleManager,

          # Main pool manager
          {Snakepit.Pool, [size: pool_size]},

          # Application cleanup for hard process termination guarantees
          # MUST BE LAST - terminates FIRST to ensure workers have shut down
          Snakepit.Pool.ApplicationCleanup
        ]
      else
        Logger.info("🔧 Starting Snakepit with pooling disabled")
        []
      end

    children = base_children ++ pool_children

    opts = [strategy: :one_for_one, name: Snakepit.Supervisor]
    result = Supervisor.start_link(children, opts)
    IO.inspect(System.monotonic_time(:millisecond), label: "Snakepit.Application started at")
    result
  end

  @impl true
  def stop(_state) do
    IO.inspect(System.monotonic_time(:millisecond),
      label: "Snakepit.Application.stop/1 called at"
    )

    :ok
  end

  # Private helper functions

  defp ensure_thread_capacity_table do
    table_name = :snakepit_worker_capacity

    case :ets.info(table_name) do
      :undefined ->
        :ets.new(table_name, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

        Logger.debug("Created worker capacity ETS table: #{table_name}")

      _ ->
        # Table already exists
        :ok
    end
  end
end
