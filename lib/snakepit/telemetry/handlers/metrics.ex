defmodule Snakepit.Telemetry.Handlers.Metrics do
  @moduledoc """
  Telemetry metrics definitions for ML-related events.

  > #### Legacy Optional Module {: .warning}
  >
  > `Snakepit` does not call this module internally. It remains available for
  > compatibility and may be removed in `v0.16.0` or later.
  >
  > Prefer host-application metrics definitions and exporter integration.

  Provides `telemetry_metrics` compatible metric definitions for
  hardware detection, circuit breaker, GPU profiling, and error events.
  """

  alias Snakepit.Internal.Deprecation
  import Telemetry.Metrics

  @legacy_replacement "Define metrics in the host application around emitted telemetry events"
  @legacy_remove_after "v0.16.0"

  @doc """
  Returns all ML-related telemetry metrics definitions.

  These can be used with `TelemetryMetricsPrometheus` or other
  telemetry metrics reporters.
  """
  @spec definitions() :: [Telemetry.Metrics.t()]
  def definitions do
    mark_legacy_usage()

    hardware_metrics() ++
      circuit_breaker_metrics() ++
      gpu_profiler_metrics() ++
      error_metrics() ++
      retry_metrics()
  end

  @doc """
  Returns Prometheus-compatible metric definitions.

  Same as `definitions/0` but ensures all metrics have names
  compatible with Prometheus naming conventions.
  """
  @spec prometheus_definitions() :: [Telemetry.Metrics.t()]
  def prometheus_definitions do
    mark_legacy_usage()
    definitions()
  end

  @spec hardware_metrics() :: [Telemetry.Metrics.t()]
  defp hardware_metrics do
    [
      # Hardware detection timing
      summary(
        "snakepit.hardware.detect.duration",
        event_name: [:snakepit, :hardware, :detect, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:accelerator, :platform],
        description: "Duration of hardware detection"
      ),

      # Device selection timing
      summary(
        "snakepit.hardware.select.duration",
        event_name: [:snakepit, :hardware, :select, :stop],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:device],
        description: "Duration of device selection"
      ),

      # Cache hit/miss counts
      counter(
        "snakepit.hardware.cache.hits.total",
        event_name: [:snakepit, :hardware, :cache, :hit],
        description: "Hardware cache hits"
      ),
      counter(
        "snakepit.hardware.cache.misses.total",
        event_name: [:snakepit, :hardware, :cache, :miss],
        description: "Hardware cache misses"
      )
    ]
  end

  @spec circuit_breaker_metrics() :: [Telemetry.Metrics.t()]
  defp circuit_breaker_metrics do
    [
      # State transition counts
      counter(
        "snakepit.circuit_breaker.opened.total",
        event_name: [:snakepit, :circuit_breaker, :opened],
        tags: [:pool, :reason],
        description: "Circuit breaker open events"
      ),
      counter(
        "snakepit.circuit_breaker.closed.total",
        event_name: [:snakepit, :circuit_breaker, :closed],
        tags: [:pool],
        description: "Circuit breaker close events"
      ),
      counter(
        "snakepit.circuit_breaker.half_open.total",
        event_name: [:snakepit, :circuit_breaker, :half_open],
        tags: [:pool],
        description: "Circuit breaker half-open events"
      ),

      # Call metrics
      counter(
        "snakepit.circuit_breaker.calls.allowed.total",
        event_name: [:snakepit, :circuit_breaker, :call, :allowed],
        tags: [:pool],
        description: "Calls allowed through circuit breaker"
      ),
      counter(
        "snakepit.circuit_breaker.calls.rejected.total",
        event_name: [:snakepit, :circuit_breaker, :call, :rejected],
        tags: [:pool],
        description: "Calls rejected by circuit breaker"
      ),
      summary(
        "snakepit.circuit_breaker.call.duration",
        event_name: [:snakepit, :circuit_breaker, :call, :success],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:pool],
        description: "Duration of successful circuit breaker calls"
      ),

      # Failure count at open time
      last_value(
        "snakepit.circuit_breaker.failure_count",
        event_name: [:snakepit, :circuit_breaker, :opened],
        measurement: :failure_count,
        tags: [:pool],
        description: "Failure count when circuit breaker opened"
      )
    ]
  end

  @spec gpu_profiler_metrics() :: [Telemetry.Metrics.t()]
  defp gpu_profiler_metrics do
    [
      # GPU memory
      last_value(
        "snakepit.gpu.memory.used_mb",
        event_name: [:snakepit, :gpu, :memory, :sampled],
        measurement: :used_mb,
        tags: [:device],
        description: "GPU memory used in MB"
      ),
      last_value(
        "snakepit.gpu.memory.total_mb",
        event_name: [:snakepit, :gpu, :memory, :sampled],
        measurement: :total_mb,
        tags: [:device],
        description: "GPU total memory in MB"
      ),
      last_value(
        "snakepit.gpu.memory.free_mb",
        event_name: [:snakepit, :gpu, :memory, :sampled],
        measurement: :free_mb,
        tags: [:device],
        description: "GPU free memory in MB"
      ),

      # GPU utilization
      last_value(
        "snakepit.gpu.utilization.percent",
        event_name: [:snakepit, :gpu, :utilization, :sampled],
        measurement: :gpu_percent,
        tags: [:device],
        description: "GPU utilization percentage"
      ),

      # GPU temperature
      last_value(
        "snakepit.gpu.temperature.celsius",
        event_name: [:snakepit, :gpu, :temperature, :sampled],
        measurement: :celsius,
        tags: [:device],
        description: "GPU temperature in Celsius"
      ),

      # GPU power
      last_value(
        "snakepit.gpu.power.watts",
        event_name: [:snakepit, :gpu, :power, :sampled],
        measurement: :watts,
        tags: [:device],
        description: "GPU power usage in watts"
      )
    ]
  end

  @spec error_metrics() :: [Telemetry.Metrics.t()]
  defp error_metrics do
    [
      # Error type counts
      counter(
        "snakepit.errors.shape_mismatch.total",
        event_name: [:snakepit, :error, :shape_mismatch],
        tags: [:operation],
        description: "Shape mismatch errors"
      ),
      counter(
        "snakepit.errors.device.total",
        event_name: [:snakepit, :error, :device],
        description: "Device mismatch errors"
      ),
      counter(
        "snakepit.errors.oom.total",
        event_name: [:snakepit, :error, :oom],
        tags: [:device],
        description: "Out of memory errors"
      ),
      counter(
        "snakepit.errors.dtype_mismatch.total",
        event_name: [:snakepit, :error, :dtype_mismatch],
        description: "Data type mismatch errors"
      ),
      counter(
        "snakepit.errors.python_exception.total",
        event_name: [:snakepit, :error, :python_exception],
        tags: [:type],
        description: "Python exceptions"
      )
    ]
  end

  @spec retry_metrics() :: [Telemetry.Metrics.t()]
  defp retry_metrics do
    [
      # Retry attempts
      summary(
        "snakepit.retry.attempts",
        event_name: [:snakepit, :retry, :success],
        measurement: :attempts,
        tags: [:pool],
        description: "Number of retry attempts before success"
      ),

      # Retry exhaustion
      counter(
        "snakepit.retry.exhausted.total",
        event_name: [:snakepit, :retry, :exhausted],
        tags: [:pool],
        description: "Retry exhaustion events"
      ),

      # Backoff delays
      summary(
        "snakepit.retry.backoff.delay_ms",
        event_name: [:snakepit, :retry, :backoff],
        measurement: :delay_ms,
        tags: [:pool],
        description: "Retry backoff delay in milliseconds"
      )
    ]
  end

  defp mark_legacy_usage do
    Deprecation.emit_legacy_module_used(__MODULE__,
      replacement: @legacy_replacement,
      remove_after: @legacy_remove_after
    )
  end
end
