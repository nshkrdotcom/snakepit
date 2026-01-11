defmodule Snakepit.Defaults do
  @moduledoc """
  Centralized defaults for all configurable values in Snakepit.

  This module provides functions that read from `Application.get_env(:snakepit, key, default)`
  for every configurable value. This allows operators to override defaults via application
  configuration while maintaining backward compatibility.

  All defaults are the EXACT values that were previously hardcoded throughout the codebase.
  Snakepit behaves identically before and after this change unless configuration is explicitly
  provided.

  ## Configuration Example

      # config/runtime.exs
      config :snakepit,
        # Timeouts
        default_command_timeout: 30_000,
        pool_request_timeout: 60_000,
        pool_streaming_timeout: 300_000,
        pool_startup_timeout: 10_000,
        pool_queue_timeout: 5_000,
        checkout_timeout: 5_000,
        grpc_worker_execute_timeout: 30_000,
        grpc_worker_stream_timeout: 300_000,
        grpc_command_timeout: 30_000,
        executor_batch_timeout: 30_000,
        health_check_interval: 30_000,
        circuit_breaker_reset_timeout: 30_000,
        graceful_shutdown_timeout_ms: 6_000,

        # Pool settings
        pool_max_queue_size: 1000,
        pool_max_workers: 150,
        pool_max_cancelled_entries: 1024,
        pool_cancelled_retention_multiplier: 4,
        pool_startup_batch_size: 10,
        pool_startup_batch_delay_ms: 500,

        # Retry settings
        retry_max_attempts: 3,
        retry_max_backoff_ms: 30_000,
        retry_jitter_factor: 0.25,
        retry_backoff_sequence: [100, 200, 400, 800, 1600],

        # Circuit breaker settings
        circuit_breaker_failure_threshold: 5,
        circuit_breaker_half_open_max_calls: 1,

        # Crash barrier settings
        crash_barrier_taint_duration_ms: 60_000,
        crash_barrier_max_restarts: 1,
        crash_barrier_backoff_ms: [50, 100, 200],

        # Health monitor settings
        health_monitor_crash_window_ms: 60_000,
        health_monitor_max_crashes: 10,

        # Lifecycle manager settings
        lifecycle_check_interval: 60_000,
        lifecycle_health_check_interval: 300_000,

        # Session store settings
        session_cleanup_interval: 60_000,
        session_default_ttl: 3600,
        session_max_sessions: 10_000,
        session_warning_threshold: 0.8,
        affinity: :hint,

        # Process registry settings
        process_registry_cleanup_interval: 30_000,
        process_registry_unregister_cleanup_delay: 500,
        process_registry_unregister_cleanup_attempts: 10,

        # gRPC settings
        grpc_num_acceptors: 20,
        grpc_max_connections: 1000,
        grpc_socket_backlog: 512,

        # Heartbeat settings
        heartbeat_ping_interval_ms: 2_000,
        heartbeat_timeout_ms: 10_000,
        heartbeat_max_missed: 3,
        heartbeat_initial_delay_ms: 0

  ## Usage

  Instead of hardcoding values like `30_000`, modules now call:

      Snakepit.Defaults.default_command_timeout()

  This returns the configured value or the original default if not configured.

  ## Timeout Profiles (v0.8.8+)

  Snakepit supports profile-based timeout configuration for different deployment scenarios:

  | Profile | default_timeout | stream_timeout | queue_timeout |
  |---------|-----------------|----------------|---------------|
  | :balanced | 300_000 (5m) | 900_000 (15m) | 10_000 (10s) |
  | :production | 300_000 (5m) | 900_000 (15m) | 10_000 (10s) |
  | :production_strict | 60_000 (60s) | 300_000 (5m) | 5_000 (5s) |
  | :development | 900_000 (15m) | 3_600_000 (60m) | 60_000 (60s) |
  | :ml_inference | 900_000 (15m) | 3_600_000 (60m) | 60_000 (60s) |
  | :batch | 3_600_000 (60m) | :infinity | 300_000 (5m) |

  Configure via:

      config :snakepit, timeout_profile: :production

  Legacy per-key configuration is still supported and takes precedence when set.
  """

  # ============================================================================
  # Timeout Profiles (NEW API)
  # ============================================================================

  @timeout_profiles %{
    balanced: %{
      default_timeout: 300_000,
      stream_timeout: 900_000,
      queue_timeout: 10_000
    },
    production: %{
      default_timeout: 300_000,
      stream_timeout: 900_000,
      queue_timeout: 10_000
    },
    production_strict: %{
      default_timeout: 60_000,
      stream_timeout: 300_000,
      queue_timeout: 5_000
    },
    development: %{
      default_timeout: 900_000,
      stream_timeout: 3_600_000,
      queue_timeout: 60_000
    },
    ml_inference: %{
      default_timeout: 900_000,
      stream_timeout: 3_600_000,
      queue_timeout: 60_000
    },
    batch: %{
      default_timeout: 3_600_000,
      stream_timeout: :infinity,
      queue_timeout: 300_000
    }
  }

  @doc """
  Returns all available timeout profiles.

  Each profile contains `default_timeout`, `stream_timeout`, and `queue_timeout` values.
  """
  @spec timeout_profiles() :: %{atom() => %{atom() => timeout()}}
  def timeout_profiles, do: @timeout_profiles

  @doc """
  Returns the currently configured timeout profile.

  Defaults to `:balanced` if not configured.
  """
  @spec timeout_profile() :: atom()
  def timeout_profile do
    Application.get_env(:snakepit, :timeout_profile, :balanced)
  end

  @doc """
  Returns the default timeout for regular execute operations based on the current profile.

  This is the primary user-facing timeout API. Legacy getters derive from this value
  when not explicitly configured.
  """
  @spec default_timeout() :: timeout()
  def default_timeout do
    profile = timeout_profile()
    get_in(@timeout_profiles, [profile, :default_timeout]) || 300_000
  end

  @doc """
  Returns the default timeout for streaming operations based on the current profile.
  """
  @spec stream_timeout() :: timeout()
  def stream_timeout do
    profile = timeout_profile()
    get_in(@timeout_profiles, [profile, :stream_timeout]) || 900_000
  end

  @doc """
  Returns the default queue timeout based on the current profile.
  """
  @spec queue_timeout() :: timeout()
  def queue_timeout do
    profile = timeout_profile()
    get_in(@timeout_profiles, [profile, :queue_timeout]) || 10_000
  end

  # ============================================================================
  # Margin Configuration
  # ============================================================================

  @doc """
  Margin reserved for GenServer.call overhead when routing to workers.

  This is subtracted from the total timeout budget to derive the RPC timeout.

  Default: 1000 ms
  """
  @spec worker_call_margin_ms() :: pos_integer()
  def worker_call_margin_ms do
    Application.get_env(:snakepit, :worker_call_margin_ms, 1000)
  end

  @doc """
  Margin reserved for pool reply overhead.

  This is subtracted from the total timeout budget to derive the RPC timeout.

  Default: 200 ms
  """
  @spec pool_reply_margin_ms() :: pos_integer()
  def pool_reply_margin_ms do
    Application.get_env(:snakepit, :pool_reply_margin_ms, 200)
  end

  @doc """
  Derives the RPC (inner) timeout from the total timeout budget.

  Formula: `rpc_timeout = total_timeout - worker_call_margin_ms - pool_reply_margin_ms`

  This ensures inner timeouts expire before outer GenServer.call timeouts,
  producing structured error returns instead of unhandled exits.

  ## Examples

      iex> Snakepit.Defaults.rpc_timeout(60_000)
      58_800  # 60_000 - 1000 - 200

      iex> Snakepit.Defaults.rpc_timeout(:infinity)
      :infinity
  """
  @spec rpc_timeout(timeout()) :: timeout()
  def rpc_timeout(:infinity), do: :infinity

  def rpc_timeout(total_timeout) when is_integer(total_timeout) do
    margins = worker_call_margin_ms() + pool_reply_margin_ms()
    result = total_timeout - margins
    # Floor at minimum usable timeout
    max(result, 1)
  end

  # ============================================================================
  # Pool Timeouts (Legacy API - now derives from new budgets)
  # ============================================================================

  @doc """
  Default timeout for pool execute calls.
  Used in `Snakepit.Pool.execute/3`.

  When not explicitly configured, derives from `default_timeout/0` based on the
  current timeout profile.

  Default: derived from profile (300_000 ms for :balanced)
  """
  @spec pool_request_timeout() :: timeout()
  def pool_request_timeout do
    Application.get_env(:snakepit, :pool_request_timeout) || default_timeout()
  end

  @doc """
  Default timeout for pool streaming calls.
  Used in `Snakepit.Pool.execute_stream/4`.

  When not explicitly configured, derives from `stream_timeout/0` based on the
  current timeout profile.

  Default: derived from profile (900_000 ms for :balanced)
  """
  @spec pool_streaming_timeout() :: timeout()
  def pool_streaming_timeout do
    Application.get_env(:snakepit, :pool_streaming_timeout) || stream_timeout()
  end

  @doc """
  Default timeout for worker startup.
  Used in pool initialization.

  Default: 10_000 ms (10 seconds)
  """
  @spec pool_startup_timeout() :: timeout()
  def pool_startup_timeout do
    Application.get_env(:snakepit, :pool_startup_timeout, 10_000)
  end

  @doc """
  Default timeout for queued requests.
  Used in `Snakepit.Pool` for queue management.

  When not explicitly configured, derives from `queue_timeout/0` based on the
  current timeout profile.

  Default: derived from profile (10_000 ms for :balanced)
  """
  @spec pool_queue_timeout() :: timeout()
  def pool_queue_timeout do
    Application.get_env(:snakepit, :pool_queue_timeout) || queue_timeout()
  end

  @doc """
  Default timeout for checking out a worker for streaming.
  Used in `Snakepit.Pool` for worker checkout during streaming operations.

  When not explicitly configured, derives from `queue_timeout/0` based on the
  current timeout profile.

  Default: derived from profile (10_000 ms for :balanced)
  """
  @spec checkout_timeout() :: timeout()
  def checkout_timeout do
    Application.get_env(:snakepit, :checkout_timeout) || queue_timeout()
  end

  @doc """
  Default command timeout for worker execute operations.
  Used in `Snakepit.Pool` for command timeout calculation.

  When not explicitly configured, derives from `rpc_timeout(default_timeout())` based on the
  current timeout profile.

  Default: derived from profile (rpc_timeout of default_timeout)
  """
  @spec default_command_timeout() :: timeout()
  def default_command_timeout do
    Application.get_env(:snakepit, :default_command_timeout) || rpc_timeout(default_timeout())
  end

  # ============================================================================
  # Pool Sizing
  # ============================================================================

  @doc """
  Default pool size based on system schedulers.
  Used when no explicit pool_size is configured.

  Default: System.schedulers_online() * 2
  """
  @spec default_pool_size() :: pos_integer()
  def default_pool_size do
    Application.get_env(:snakepit, :default_pool_size, System.schedulers_online() * 2)
  end

  @doc """
  Maximum queue size for pending requests.
  Used in `Snakepit.Pool` for queue management.

  Default: 1000
  """
  @spec pool_max_queue_size() :: pos_integer()
  def pool_max_queue_size do
    Application.get_env(:snakepit, :pool_max_queue_size, 1000)
  end

  @doc """
  Maximum number of workers allowed per pool.
  Used in `Snakepit.Pool` for worker limit enforcement.

  Default: 150
  """
  @spec pool_max_workers() :: pos_integer()
  def pool_max_workers do
    Application.get_env(:snakepit, :pool_max_workers, 150)
  end

  @doc """
  Maximum number of cancelled request entries to track.
  Used in `Snakepit.Pool` for cancelled request management.

  Default: 1024
  """
  @spec pool_max_cancelled_entries() :: pos_integer()
  def pool_max_cancelled_entries do
    Application.get_env(:snakepit, :pool_max_cancelled_entries, 1024)
  end

  @doc """
  Multiplier for cancelled request retention time.
  Retention time = queue_timeout * this multiplier.

  Default: 4
  """
  @spec pool_cancelled_retention_multiplier() :: pos_integer()
  def pool_cancelled_retention_multiplier do
    Application.get_env(:snakepit, :pool_cancelled_retention_multiplier, 4)
  end

  @doc """
  Number of workers to start per batch during pool initialization.
  Used in `Snakepit.Pool` for batched startup.

  Default: 10
  """
  @spec pool_startup_batch_size() :: pos_integer()
  def pool_startup_batch_size do
    Application.get_env(:snakepit, :pool_startup_batch_size, 10)
  end

  @doc """
  Delay between worker startup batches in milliseconds.
  Used in `Snakepit.Pool` for batched startup.

  Default: 500 ms
  """
  @spec pool_startup_batch_delay_ms() :: non_neg_integer()
  def pool_startup_batch_delay_ms do
    Application.get_env(:snakepit, :pool_startup_batch_delay_ms, 500)
  end

  @spec pool_reconcile_interval_ms() :: non_neg_integer()
  def pool_reconcile_interval_ms do
    Application.get_env(:snakepit, :pool_reconcile_interval_ms, 1_000)
  end

  @spec pool_reconcile_batch_size() :: pos_integer()
  def pool_reconcile_batch_size do
    Application.get_env(:snakepit, :pool_reconcile_batch_size, 2)
  end

  # ============================================================================
  # gRPC Worker
  # ============================================================================

  @doc """
  Default timeout for GRPCWorker execute calls.
  Used in `Snakepit.GRPCWorker.execute/4`.

  When not explicitly configured, derives from `rpc_timeout(default_timeout())` based on the
  current timeout profile.

  Default: derived from profile (rpc_timeout of default_timeout)
  """
  @spec grpc_worker_execute_timeout() :: timeout()
  def grpc_worker_execute_timeout do
    Application.get_env(:snakepit, :grpc_worker_execute_timeout) || rpc_timeout(default_timeout())
  end

  @doc """
  Default timeout for GRPCWorker streaming calls.
  Used in `Snakepit.GRPCWorker.execute_stream/5`.

  Default: derived from `stream_timeout/0`
  """
  @spec grpc_worker_stream_timeout() :: timeout()
  def grpc_worker_stream_timeout do
    Application.get_env(:snakepit, :grpc_worker_stream_timeout, stream_timeout())
  end

  @doc """
  Graceful shutdown timeout for Python process termination.
  Must be >= Python's shutdown envelope: server.stop(2s) + wait_for_termination(3s) = 5s.

  Default: 6_000 ms (6 seconds)
  """
  @spec graceful_shutdown_timeout_ms() :: pos_integer()
  def graceful_shutdown_timeout_ms do
    Application.get_env(:snakepit, :graceful_shutdown_timeout_ms, 6_000)
  end

  @doc """
  Margin added to graceful_shutdown_timeout for supervisor shutdown.
  This gives the worker time to complete its terminate/2 callback.

  Default: 2_000 ms (2 seconds)
  """
  @spec shutdown_margin_ms() :: pos_integer()
  def shutdown_margin_ms do
    Application.get_env(:snakepit, :shutdown_margin_ms, 2_000)
  end

  @doc """
  Interval for health checks in GRPCWorker.
  Used in `Snakepit.GRPCWorker` for periodic health check scheduling.

  Default: 30_000 ms (30 seconds)
  """
  @spec grpc_worker_health_check_interval() :: pos_integer()
  def grpc_worker_health_check_interval do
    Application.get_env(:snakepit, :grpc_worker_health_check_interval, 30_000)
  end

  # ============================================================================
  # Heartbeat
  # ============================================================================

  @doc """
  Default heartbeat ping interval.
  Used in `Snakepit.GRPCWorker` heartbeat configuration.

  Default: 2_000 ms (2 seconds)
  """
  @spec heartbeat_ping_interval_ms() :: pos_integer()
  def heartbeat_ping_interval_ms do
    Application.get_env(:snakepit, :heartbeat_ping_interval_ms, 2_000)
  end

  @doc """
  Default heartbeat timeout.
  Used in `Snakepit.GRPCWorker` heartbeat configuration.

  Default: 10_000 ms (10 seconds)
  """
  @spec heartbeat_timeout_ms() :: pos_integer()
  def heartbeat_timeout_ms do
    Application.get_env(:snakepit, :heartbeat_timeout_ms, 10_000)
  end

  @doc """
  Maximum missed heartbeats before worker is considered unhealthy.
  Used in `Snakepit.GRPCWorker` heartbeat configuration.

  Default: 3
  """
  @spec heartbeat_max_missed() :: pos_integer()
  def heartbeat_max_missed do
    Application.get_env(:snakepit, :heartbeat_max_missed, 3)
  end

  @doc """
  Initial delay before starting heartbeat monitoring.
  Used in `Snakepit.GRPCWorker` heartbeat configuration.

  Default: 0 ms
  """
  @spec heartbeat_initial_delay_ms() :: non_neg_integer()
  def heartbeat_initial_delay_ms do
    Application.get_env(:snakepit, :heartbeat_initial_delay_ms, 0)
  end

  # ============================================================================
  # gRPC Python Adapter
  # ============================================================================

  @doc """
  Default command timeout for gRPC adapter.
  Used in `Snakepit.Adapters.GRPCPython` for default command timeouts.

  When not explicitly configured, derives from `rpc_timeout(default_timeout())` based on the
  current timeout profile.

  Default: derived from profile (rpc_timeout of default_timeout)
  """
  @spec grpc_command_timeout() :: timeout()
  def grpc_command_timeout do
    Application.get_env(:snakepit, :grpc_command_timeout) || rpc_timeout(default_timeout())
  end

  @doc """
  Timeout for batch inference commands.
  Used in `Snakepit.Adapters.GRPCPython` for batch inference operations.

  Default: 300_000 ms (5 minutes)
  """
  @spec grpc_batch_inference_timeout() :: timeout()
  def grpc_batch_inference_timeout do
    Application.get_env(:snakepit, :grpc_batch_inference_timeout, 300_000)
  end

  @doc """
  Timeout for large dataset processing commands.
  Used in `Snakepit.Adapters.GRPCPython` for large dataset processing operations.

  Default: 600_000 ms (10 minutes)
  """
  @spec grpc_large_dataset_timeout() :: timeout()
  def grpc_large_dataset_timeout do
    Application.get_env(:snakepit, :grpc_large_dataset_timeout, 600_000)
  end

  # ============================================================================
  # Executor
  # ============================================================================

  @doc """
  Default timeout for batch operations in Executor.
  Used in `Snakepit.Executor.execute_batch/2`.

  Default: 30_000 ms (30 seconds)
  """
  @spec executor_batch_timeout() :: timeout()
  def executor_batch_timeout do
    Application.get_env(:snakepit, :executor_batch_timeout, 30_000)
  end

  # ============================================================================
  # Health Monitor
  # ============================================================================

  @doc """
  Default interval for health monitor cleanup.
  Used in `Snakepit.HealthMonitor`.

  Default: 30_000 ms (30 seconds)
  """
  @spec health_monitor_check_interval() :: pos_integer()
  def health_monitor_check_interval do
    Application.get_env(:snakepit, :health_monitor_check_interval, 30_000)
  end

  @doc """
  Default crash window for health monitor.
  Rolling window for crash counting.

  Default: 60_000 ms (1 minute)
  """
  @spec health_monitor_crash_window_ms() :: pos_integer()
  def health_monitor_crash_window_ms do
    Application.get_env(:snakepit, :health_monitor_crash_window_ms, 60_000)
  end

  @doc """
  Default max crashes before pool is considered unhealthy.
  Used in `Snakepit.HealthMonitor`.

  Default: 10
  """
  @spec health_monitor_max_crashes() :: pos_integer()
  def health_monitor_max_crashes do
    Application.get_env(:snakepit, :health_monitor_max_crashes, 10)
  end

  # ============================================================================
  # Retry Policy
  # ============================================================================

  @doc """
  Default maximum retry attempts.
  Used in `Snakepit.RetryPolicy`.

  Default: 3
  """
  @spec retry_max_attempts() :: pos_integer()
  def retry_max_attempts do
    Application.get_env(:snakepit, :retry_max_attempts, 3)
  end

  @doc """
  Default backoff sequence for retries.
  Used in `Snakepit.RetryPolicy`.

  Default: [100, 200, 400, 800, 1600]
  """
  @spec retry_backoff_sequence() :: [pos_integer()]
  def retry_backoff_sequence do
    Application.get_env(:snakepit, :retry_backoff_sequence, [100, 200, 400, 800, 1600])
  end

  @doc """
  Default base backoff for retry calculations.
  Used in `Snakepit.RetryPolicy`.

  Default: 100 ms
  """
  @spec retry_base_backoff_ms() :: pos_integer()
  def retry_base_backoff_ms do
    Application.get_env(:snakepit, :retry_base_backoff_ms, 100)
  end

  @doc """
  Default maximum backoff delay.
  Used in `Snakepit.RetryPolicy`.

  Default: 30_000 ms (30 seconds)
  """
  @spec retry_max_backoff_ms() :: pos_integer()
  def retry_max_backoff_ms do
    Application.get_env(:snakepit, :retry_max_backoff_ms, 30_000)
  end

  @doc """
  Default backoff multiplier for exponential backoff.
  Used in `Snakepit.RetryPolicy`.

  Default: 2.0
  """
  @spec retry_backoff_multiplier() :: float()
  def retry_backoff_multiplier do
    Application.get_env(:snakepit, :retry_backoff_multiplier, 2.0)
  end

  @doc """
  Default jitter factor for retry delays.
  Used in `Snakepit.RetryPolicy`.

  Default: 0.25 (25%)
  """
  @spec retry_jitter_factor() :: float()
  def retry_jitter_factor do
    Application.get_env(:snakepit, :retry_jitter_factor, 0.25)
  end

  # ============================================================================
  # Circuit Breaker
  # ============================================================================

  @doc """
  Default failure threshold before circuit opens.
  Used in `Snakepit.CircuitBreaker`.

  Default: 5
  """
  @spec circuit_breaker_failure_threshold() :: pos_integer()
  def circuit_breaker_failure_threshold do
    Application.get_env(:snakepit, :circuit_breaker_failure_threshold, 5)
  end

  @doc """
  Default reset timeout before transitioning to half-open.
  Used in `Snakepit.CircuitBreaker`.

  Default: 30_000 ms (30 seconds)
  """
  @spec circuit_breaker_reset_timeout_ms() :: pos_integer()
  def circuit_breaker_reset_timeout_ms do
    Application.get_env(:snakepit, :circuit_breaker_reset_timeout_ms, 30_000)
  end

  @doc """
  Default max calls allowed in half-open state.
  Used in `Snakepit.CircuitBreaker`.

  Default: 1
  """
  @spec circuit_breaker_half_open_max_calls() :: pos_integer()
  def circuit_breaker_half_open_max_calls do
    Application.get_env(:snakepit, :circuit_breaker_half_open_max_calls, 1)
  end

  # ============================================================================
  # Crash Barrier
  # ============================================================================

  @doc """
  Default taint duration for crashed workers.
  Used in `Snakepit.CrashBarrier`.

  Default: 60_000 ms (1 minute)
  """
  @spec crash_barrier_taint_duration_ms() :: pos_integer()
  def crash_barrier_taint_duration_ms do
    Application.get_env(:snakepit, :crash_barrier_taint_duration_ms, 60_000)
  end

  @doc """
  Default max restarts for crash barrier retry.
  Used in `Snakepit.CrashBarrier`.

  Default: 1
  """
  @spec crash_barrier_max_restarts() :: pos_integer()
  def crash_barrier_max_restarts do
    Application.get_env(:snakepit, :crash_barrier_max_restarts, 1)
  end

  @doc """
  Default backoff sequence for crash barrier retries.
  Used in `Snakepit.CrashBarrier`.

  Default: [50, 100, 200]
  """
  @spec crash_barrier_backoff_ms() :: [pos_integer()]
  def crash_barrier_backoff_ms do
    Application.get_env(:snakepit, :crash_barrier_backoff_ms, [50, 100, 200])
  end

  @spec worker_starter_max_restarts() :: non_neg_integer()
  def worker_starter_max_restarts do
    Application.get_env(:snakepit, :worker_starter_max_restarts, 3)
  end

  @spec worker_starter_max_seconds() :: pos_integer()
  def worker_starter_max_seconds do
    Application.get_env(:snakepit, :worker_starter_max_seconds, 5)
  end

  @spec worker_supervisor_max_restarts() :: non_neg_integer()
  def worker_supervisor_max_restarts do
    Application.get_env(:snakepit, :worker_supervisor_max_restarts, 3)
  end

  @spec worker_supervisor_max_seconds() :: pos_integer()
  def worker_supervisor_max_seconds do
    Application.get_env(:snakepit, :worker_supervisor_max_seconds, 5)
  end

  # ============================================================================
  # Lifecycle Manager
  # ============================================================================

  @doc """
  Default interval for lifecycle checks.
  Used in `Snakepit.Worker.LifecycleManager`.

  Default: 60_000 ms (1 minute)
  """
  @spec lifecycle_check_interval() :: pos_integer()
  def lifecycle_check_interval do
    Application.get_env(:snakepit, :lifecycle_check_interval, 60_000)
  end

  @doc """
  Default interval for health checks in lifecycle manager.
  Used in `Snakepit.Worker.LifecycleManager`.

  Default: 300_000 ms (5 minutes)
  """
  @spec lifecycle_health_check_interval() :: pos_integer()
  def lifecycle_health_check_interval do
    Application.get_env(:snakepit, :lifecycle_health_check_interval, 300_000)
  end

  # ============================================================================
  # Session Store
  # ============================================================================

  @doc """
  Default cleanup interval for expired sessions.
  Used in `Snakepit.Bridge.SessionStore`.

  Default: 60_000 ms (1 minute)
  """
  @spec session_cleanup_interval() :: pos_integer()
  def session_cleanup_interval do
    Application.get_env(:snakepit, :session_cleanup_interval, 60_000)
  end

  @doc """
  Default TTL for sessions in seconds.
  Used in `Snakepit.Bridge.SessionStore`.

  Default: 3600 seconds (1 hour)
  """
  @spec session_default_ttl() :: pos_integer()
  def session_default_ttl do
    Application.get_env(:snakepit, :session_default_ttl, 3600)
  end

  @doc """
  Default maximum number of sessions.
  Used in `Snakepit.Bridge.SessionStore`.

  Default: 10_000
  """
  @spec session_max_sessions() :: pos_integer() | :infinity
  def session_max_sessions do
    Application.get_env(:snakepit, :session_max_sessions, 10_000)
  end

  @doc """
  Session warning threshold as a fraction of max_sessions.
  When session count exceeds this percentage, warnings are emitted.

  Default: 0.8 (80%)
  """
  @spec session_warning_threshold() :: float()
  def session_warning_threshold do
    Application.get_env(:snakepit, :session_warning_threshold, 0.8)
  end

  # ============================================================================
  # Process Registry
  # ============================================================================

  @doc """
  Default cleanup interval for process registry.
  Used in `Snakepit.Pool.ProcessRegistry`.

  Default: 30_000 ms (30 seconds)
  """
  @spec process_registry_cleanup_interval() :: pos_integer()
  def process_registry_cleanup_interval do
    Application.get_env(:snakepit, :process_registry_cleanup_interval, 30_000)
  end

  @doc """
  Delay before retrying unregister when external process is still alive.
  Used in `Snakepit.Pool.ProcessRegistry`.

  Default: 500 ms
  """
  @spec process_registry_unregister_cleanup_delay() :: pos_integer()
  def process_registry_unregister_cleanup_delay do
    Application.get_env(:snakepit, :process_registry_unregister_cleanup_delay, 500)
  end

  @doc """
  Maximum attempts to retry unregister cleanup.
  Used in `Snakepit.Pool.ProcessRegistry`.

  Default: 10
  """
  @spec process_registry_unregister_cleanup_attempts() :: pos_integer()
  def process_registry_unregister_cleanup_attempts do
    Application.get_env(:snakepit, :process_registry_unregister_cleanup_attempts, 10)
  end

  # ============================================================================
  # gRPC Server Configuration
  # ============================================================================

  @doc """
  Default number of acceptors for gRPC server.
  Used in `Snakepit.Application`.

  Default: 20
  """
  @spec grpc_num_acceptors() :: pos_integer()
  def grpc_num_acceptors do
    Application.get_env(:snakepit, :grpc_num_acceptors, 20)
  end

  @doc """
  Default maximum connections for gRPC server.
  Used in `Snakepit.Application`.

  Default: 1000
  """
  @spec grpc_max_connections() :: pos_integer()
  def grpc_max_connections do
    Application.get_env(:snakepit, :grpc_max_connections, 1000)
  end

  @doc """
  Default socket backlog for gRPC server.
  Used in `Snakepit.Application`.

  Default: 512
  """
  @spec grpc_socket_backlog() :: pos_integer()
  def grpc_socket_backlog do
    Application.get_env(:snakepit, :grpc_socket_backlog, 512)
  end

  # ============================================================================
  # Config Module Defaults
  # ============================================================================

  @doc """
  Default worker profile.
  Used in `Snakepit.Config`.

  Default: :process
  """
  @spec default_worker_profile() :: :process | :thread
  def default_worker_profile do
    Application.get_env(:snakepit, :default_worker_profile, :process)
  end

  @doc """
  Default batch size for process profile.
  Used in `Snakepit.Config`.

  Default: 8
  """
  @spec config_default_batch_size() :: pos_integer()
  def config_default_batch_size do
    Application.get_env(:snakepit, :config_default_batch_size, 8)
  end

  @doc """
  Default batch delay for process profile.
  Used in `Snakepit.Config`.

  Default: 750 ms
  """
  @spec config_default_batch_delay() :: pos_integer()
  def config_default_batch_delay do
    Application.get_env(:snakepit, :config_default_batch_delay, 750)
  end

  @doc """
  Default threads per worker for thread profile.
  Used in `Snakepit.Config`.

  Default: 10
  """
  @spec config_default_threads_per_worker() :: pos_integer()
  def config_default_threads_per_worker do
    Application.get_env(:snakepit, :config_default_threads_per_worker, 10)
  end

  @doc """
  Default capacity strategy.
  Used in `Snakepit.Config`.

  Default: :pool
  """
  @spec default_capacity_strategy() :: :pool | :profile | :hybrid
  def default_capacity_strategy do
    Application.get_env(:snakepit, :default_capacity_strategy, :pool)
  end

  # ============================================================================
  # gRPC Client
  # ============================================================================

  @doc """
  Default timeout for gRPC client execute calls.
  Used in `Snakepit.GRPC.Client`.

  Default: derived from `grpc_command_timeout/0`
  """
  @spec grpc_client_execute_timeout() :: timeout()
  def grpc_client_execute_timeout do
    Application.get_env(:snakepit, :grpc_client_execute_timeout, grpc_command_timeout())
  end

  # ============================================================================
  # gRPC Listener
  # ============================================================================

  @doc """
  Default host for internal-only gRPC listeners.
  Used when `grpc_listener.mode` is `:internal`.

  Default: "127.0.0.1"
  """
  @spec grpc_internal_host() :: String.t()
  def grpc_internal_host do
    Application.get_env(:snakepit, :grpc_internal_host, "127.0.0.1")
  end

  @doc """
  Default port pool size for external pooled listeners.
  Used when `grpc_listener.mode` is `:external_pool`.

  Default: 32
  """
  @spec grpc_port_pool_size() :: pos_integer()
  def grpc_port_pool_size do
    Application.get_env(:snakepit, :grpc_port_pool_size, 32)
  end

  @doc """
  Timeout for waiting on the gRPC listener to publish its assigned port.

  Default: 5_000 ms
  """
  @spec grpc_listener_ready_timeout_ms() :: pos_integer()
  def grpc_listener_ready_timeout_ms do
    Application.get_env(:snakepit, :grpc_listener_ready_timeout_ms, 5_000)
  end

  @doc """
  Interval (ms) between port readiness checks when reusing an existing gRPC listener.

  Default: 25 ms
  """
  @spec grpc_listener_port_check_interval_ms() :: pos_integer()
  def grpc_listener_port_check_interval_ms do
    Application.get_env(:snakepit, :grpc_listener_port_check_interval_ms, 25)
  end

  @doc """
  Number of attempts to reuse or rebind a gRPC listener before failing.

  Default: 3
  """
  @spec grpc_listener_reuse_attempts() :: pos_integer()
  def grpc_listener_reuse_attempts do
    Application.get_env(:snakepit, :grpc_listener_reuse_attempts, 3)
  end

  @doc """
  Max wait (ms) for an already-started gRPC listener to publish its port before retrying.

  Default: 500 ms
  """
  @spec grpc_listener_reuse_wait_timeout_ms() :: pos_integer()
  def grpc_listener_reuse_wait_timeout_ms do
    Application.get_env(:snakepit, :grpc_listener_reuse_wait_timeout_ms, 500)
  end

  @doc """
  Delay (ms) between gRPC listener reuse retries.

  Default: 100 ms
  """
  @spec grpc_listener_reuse_retry_delay_ms() :: pos_integer()
  def grpc_listener_reuse_retry_delay_ms do
    Application.get_env(:snakepit, :grpc_listener_reuse_retry_delay_ms, 100)
  end

  # ============================================================================
  # Application
  # ============================================================================

  @doc """
  Default gRPC port for Elixir server.
  Legacy: used when `grpc_listener` is not configured.

  Default: 50_051
  """
  @spec grpc_port() :: pos_integer()
  def grpc_port do
    Application.get_env(:snakepit, :grpc_port, 50_051)
  end

  @doc """
  Timeout for cleanup on stop.
  Used in `Snakepit.Application`.

  Default: 3_000 ms (3 seconds)
  """
  @spec cleanup_on_stop_timeout_ms() :: pos_integer()
  def cleanup_on_stop_timeout_ms do
    Application.get_env(:snakepit, :cleanup_on_stop_timeout_ms, 3_000)
  end

  @doc """
  Poll interval for cleanup operations.
  Used in `Snakepit.Application`.

  Default: 50 ms
  """
  @spec cleanup_poll_interval_ms() :: pos_integer()
  def cleanup_poll_interval_ms do
    Application.get_env(:snakepit, :cleanup_poll_interval_ms, 50)
  end

  # ============================================================================
  # Crash Barrier Worker Checkout
  # ============================================================================

  @doc """
  Timeout for checking out worker during crash barrier retry.
  Used in `Snakepit.Pool` crash barrier retry logic.

  Default: 5_000 ms (5 seconds)
  """
  @spec crash_barrier_checkout_timeout() :: timeout()
  def crash_barrier_checkout_timeout do
    Application.get_env(:snakepit, :crash_barrier_checkout_timeout, 5_000)
  end

  # ============================================================================
  # Pool Ready Timeout
  # ============================================================================

  @doc """
  Default timeout for awaiting pool readiness.
  Used in `Snakepit.Pool.await_ready/2`.

  Default: 15_000 ms (15 seconds)
  """
  @spec pool_await_ready_timeout() :: timeout()
  def pool_await_ready_timeout do
    Application.get_env(:snakepit, :pool_await_ready_timeout, 15_000)
  end

  # ============================================================================
  # Worker Ready Notification
  # ============================================================================

  @doc """
  Timeout for worker ready notification to pool.
  Used in `Snakepit.GRPCWorker` when notifying pool of readiness.

  Default: 30_000 ms (30 seconds)
  """
  @spec worker_ready_timeout() :: timeout()
  def worker_ready_timeout do
    Application.get_env(:snakepit, :worker_ready_timeout, 30_000)
  end

  # ============================================================================
  # gRPC Server Ready Wait
  # ============================================================================

  @doc """
  Timeout for waiting for gRPC server to become ready.
  Used in `Snakepit.GRPCWorker` during initialization.

  Default: 30_000 ms (30 seconds)
  """
  @spec grpc_server_ready_timeout() :: timeout()
  def grpc_server_ready_timeout do
    Application.get_env(:snakepit, :grpc_server_ready_timeout, 30_000)
  end

  # ============================================================================
  # Session Affinity Cache
  # ============================================================================

  @doc """
  TTL for session affinity cache entries in seconds.
  Used in `Snakepit.Pool` for ETS affinity caching.

  Default: 60 seconds (1 minute)
  """
  @spec affinity_cache_ttl_seconds() :: pos_integer()
  def affinity_cache_ttl_seconds do
    Application.get_env(:snakepit, :affinity_cache_ttl_seconds, 60)
  end

  @doc """
  Default session affinity mode for pools.

  - `:hint` - Prefer the last worker when available, otherwise fall back
  - `:strict_queue` - Queue when preferred worker is busy
  - `:strict_fail_fast` - Return `{:error, :worker_busy}` when preferred worker is busy

  Default: `:hint`
  """
  @spec default_affinity_mode() :: :hint | :strict_queue | :strict_fail_fast
  def default_affinity_mode do
    Application.get_env(:snakepit, :affinity, :hint)
  end
end
