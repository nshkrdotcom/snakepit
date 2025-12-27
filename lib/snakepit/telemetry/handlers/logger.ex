defmodule Snakepit.Telemetry.Handlers.Logger do
  @moduledoc """
  Telemetry handler that logs ML-related events.

  Provides structured logging for hardware detection, circuit breaker
  state changes, GPU profiling, and error events.
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Telemetry.Events

  @handler_id "snakepit-ml-logger"
  @log_category :telemetry

  @doc """
  Attaches the logger handler to all ML events.
  """
  @spec attach() :: :ok
  def attach do
    # Detach first to allow re-attachment
    detach()

    events = Events.all_ml_events()

    :telemetry.attach_many(
      @handler_id,
      events,
      &handle_event/4,
      %{level: log_level()}
    )

    :ok
  end

  @doc """
  Detaches the logger handler.
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  rescue
    _ -> :ok
  end

  # Hardware events
  defp handle_event(
         [:snakepit, :hardware, :detect, :stop],
         %{duration: duration},
         %{accelerator: acc, platform: platform},
         config
       ) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    log(
      config.level,
      "Hardware detection completed in #{duration_ms}ms: accelerator=#{acc} platform=#{platform}"
    )
  end

  defp handle_event(
         [:snakepit, :hardware, :select, :stop],
         %{duration: duration},
         %{device: device, success: success},
         config
       ) do
    duration_us = System.convert_time_unit(duration, :native, :microsecond)

    log(
      config.level,
      "Device selection: #{inspect(device)} success=#{success} (#{duration_us}μs)"
    )
  end

  # Circuit breaker events
  defp handle_event(
         [:snakepit, :circuit_breaker, :opened],
         %{failure_count: count},
         %{pool: pool, reason: reason},
         config
       ) do
    log(
      :warning,
      "Circuit breaker OPENED for pool=#{pool}: #{count} failures, reason=#{reason}"
    )

    _ = config
  end

  defp handle_event(
         [:snakepit, :circuit_breaker, :closed],
         _measurements,
         %{pool: pool},
         config
       ) do
    log(config.level, "Circuit breaker CLOSED for pool=#{pool}")
  end

  defp handle_event(
         [:snakepit, :circuit_breaker, :half_open],
         _measurements,
         %{pool: pool},
         config
       ) do
    log(config.level, "Circuit breaker HALF-OPEN for pool=#{pool}")
  end

  defp handle_event(
         [:snakepit, :circuit_breaker, :call, :rejected],
         _measurements,
         %{pool: pool, state: state},
         config
       ) do
    log(:warning, "Circuit breaker rejected call for pool=#{pool} state=#{state}")
    _ = config
  end

  # GPU profiler events
  defp handle_event(
         [:snakepit, :gpu, :memory, :sampled],
         %{used_mb: used, total_mb: total},
         %{device: device},
         config
       ) do
    percent = Float.round(used / max(total, 1) * 100, 1)

    log(
      config.level,
      "GPU memory: #{used}/#{total}MB (#{percent}%) device=#{inspect(device)}"
    )
  end

  # Error events
  defp handle_event(
         [:snakepit, :error, :shape_mismatch],
         _measurements,
         %{expected: expected, got: got, operation: op},
         _config
       ) do
    log(:warning, "Shape mismatch in #{op}: expected #{inspect(expected)}, got #{inspect(got)}")
  end

  defp handle_event(
         [:snakepit, :error, :oom],
         %{requested_bytes: requested, available_bytes: available},
         %{device: device},
         _config
       ) do
    req_mb = Float.round(requested / 1_048_576, 1)
    avail_mb = Float.round(available / 1_048_576, 1)

    log(
      :error,
      "OOM on device=#{inspect(device)}: requested #{req_mb}MB, available #{avail_mb}MB"
    )
  end

  defp handle_event(
         [:snakepit, :error, :device],
         _measurements,
         %{expected_device: expected, actual_device: actual},
         _config
       ) do
    log(
      :warning,
      "Device mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    )
  end

  # Retry events
  defp handle_event(
         [:snakepit, :retry, :attempt],
         %{attempt: attempt, delay_ms: delay},
         %{pool: pool},
         config
       ) do
    log(config.level, "Retry attempt #{attempt} for pool=#{pool} after #{delay}ms delay")
  end

  defp handle_event(
         [:snakepit, :retry, :exhausted],
         %{attempts: attempts},
         %{pool: pool, last_error: error},
         _config
       ) do
    log(
      :error,
      "Retries exhausted for pool=#{pool} after #{attempts} attempts: #{inspect(error)}"
    )
  end

  # Catch-all for unhandled events
  defp handle_event(event, measurements, metadata, config) do
    log(
      config.level,
      "Telemetry: #{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end

  defp log(level, message) do
    case level do
      :debug -> SLog.debug(@log_category, message)
      :info -> SLog.info(@log_category, message)
      :warning -> SLog.warning(@log_category, message)
      :error -> SLog.error(@log_category, message)
      _ -> SLog.debug(@log_category, message)
    end
  end

  defp log_level do
    Application.get_env(:snakepit, :telemetry_log_level, :debug)
  end
end
