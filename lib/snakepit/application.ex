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
  alias Snakepit.Config
  alias Snakepit.Defaults
  alias Snakepit.Logger, as: SLog
  alias Snakepit.PythonThreadLimits
  alias Snakepit.Telemetry.OpenTelemetry

  @runtime_env Application.compile_env(:snakepit, :environment, :prod)

  @impl true
  def start(_type, _args) do
    configure_logging()
    Snakepit.Shutdown.clear_in_progress()

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

    if pooling_enabled and python_adapter_in_use?() do
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

    # Always start SessionStore as it's needed for tests and bridge functionality
    telemetry_children = Snakepit.TelemetryMetrics.reporter_children()

    base_children = [
      Snakepit.Bridge.SessionStore,
      Snakepit.Bridge.ToolRegistry,
      # Registry for worker process registration (needed even without pooling)
      Snakepit.Pool.Registry,
      # Process registry for PID tracking (always available for cleanup)
      Snakepit.Pool.ProcessRegistry,
      # ETS owner for shared tables used across the system
      Snakepit.ETSOwner,
      # Task supervisor for async pool operations
      {Task.Supervisor, name: Snakepit.TaskSupervisor},
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
          Snakepit.GRPC.ClientSupervisor,

          # Start the central gRPC listener and publish its assigned port
          Snakepit.GRPC.Listener,

          # Telemetry gRPC stream manager (for Python worker telemetry)
          Snakepit.Telemetry.GrpcStream,

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

    case result do
      {:ok, pid} ->
        case ensure_grpc_listener_ready(pooling_enabled) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            SLog.error(:startup, "gRPC listener failed to start", reason: reason)
            safe_stop_supervisor(pid)
            {:error, {:grpc_listener_failed, reason}}
        end

      other ->
        other
    end
  end

  @impl true
  def prep_stop(state) do
    # Mark shutdown before children stop so workers treat clean exits as expected.
    Snakepit.Shutdown.mark_in_progress()
    state
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

  defp safe_stop_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Process.unlink(pid)
      rescue
        _ -> :ok
      end

      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        Defaults.graceful_shutdown_timeout_ms() + Defaults.shutdown_margin_ms() ->
          Process.demonitor(ref, [:flush])
          :ok
      end
    end
  end

  defp ensure_grpc_listener_ready(false), do: :ok

  defp ensure_grpc_listener_ready(true) do
    with {:ok, config} <- Config.grpc_listener_config(),
         {:ok, info} <- Snakepit.GRPC.Listener.await_ready(),
         :ok <- validate_listener_info(config, info) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_listener_info(%{mode: :external, port: expected}, %{port: actual}) do
    if expected == actual do
      :ok
    else
      {:error, {:grpc_listener_port_mismatch, expected, actual}}
    end
  end

  defp validate_listener_info(
         %{mode: :external_pool, base_port: base_port, pool_size: pool_size},
         %{port: actual}
       )
       when is_integer(base_port) and is_integer(pool_size) do
    if actual in base_port..(base_port + pool_size - 1) do
      :ok
    else
      {:error, {:grpc_listener_port_mismatch, base_port, actual}}
    end
  end

  defp validate_listener_info(_config, _info), do: :ok

  defp ensure_python_ready do
    # Ensure snakepit's Python requirements are installed (auto-upgrade if needed)
    ensure_snakepit_requirements()

    # Then run the doctor checks
    doctor = Application.get_env(:snakepit, :env_doctor_module, Snakepit.EnvDoctor)
    doctor.ensure_python!()
  rescue
    error ->
      reraise error, __STACKTRACE__
  end

  defp python_adapter_in_use? do
    default_adapter =
      Application.get_env(:snakepit, :adapter_module, Snakepit.Adapters.GRPCPython)

    pools = Application.get_env(:snakepit, :pools)

    cond do
      is_list(pools) and pools != [] ->
        Enum.any?(pools, fn pool ->
          Map.get(pool, :adapter_module, default_adapter) == Snakepit.Adapters.GRPCPython
        end)

      true ->
        default_adapter == Snakepit.Adapters.GRPCPython
    end
  end

  @requirements_checked_key {__MODULE__, :requirements_checked}

  defp ensure_snakepit_requirements do
    # Only check once per BEAM session to avoid noise during tests
    if :persistent_term.get(@requirements_checked_key, false) do
      :ok
    else
      do_ensure_snakepit_requirements()
    end
  end

  defp do_ensure_snakepit_requirements do
    # Only auto-install if explicitly enabled or in dev/test environment
    runtime_env = Application.get_env(:snakepit, :environment, :prod)

    auto_install? =
      runtime_env in [:dev, :test] or
        Application.get_env(:snakepit, :auto_install_python_deps, false)

    if auto_install? do
      case snakepit_requirements_path() do
        nil ->
          :ok

        path ->
          # Use Mix.shell for dev/test feedback (Mix is always available when auto_install? is true)
          if Code.ensure_loaded?(Mix) do
            Mix.shell().info("🐍 Checking Python package requirements...")
          end

          Snakepit.PythonPackages.ensure!({:file, path}, quiet: true)
          :persistent_term.put(@requirements_checked_key, true)
      end
    end
  end

  defp snakepit_requirements_path do
    case :code.priv_dir(:snakepit) do
      {:error, _} ->
        nil

      priv_dir ->
        path = Path.join([to_string(priv_dir), "python", "requirements.txt"])
        if File.exists?(path), do: path, else: nil
    end
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
