defmodule Snakepit.Telemetry.Events do
  @moduledoc """
  ML-specific telemetry event definitions.

  Defines telemetry events for hardware detection, GPU profiling,
  circuit breaker operations, and structured exceptions.
  """

  @type event :: [atom()]
  @type measurement_type :: :integer | :float | :monotonic_time | :system_time
  @type metadata_type :: :string | :atom | :integer | :map | :list | :any

  @type schema :: %{
          measurements: %{atom() => measurement_type()},
          metadata: %{atom() => metadata_type()}
        }

  @doc """
  Returns all hardware-related telemetry events.
  """
  @spec hardware_events() :: [event()]
  def hardware_events do
    [
      [:snakepit, :hardware, :detect, :start],
      [:snakepit, :hardware, :detect, :stop],
      [:snakepit, :hardware, :select, :start],
      [:snakepit, :hardware, :select, :stop],
      [:snakepit, :hardware, :cache, :hit],
      [:snakepit, :hardware, :cache, :miss]
    ]
  end

  @doc """
  Returns all circuit breaker telemetry events.
  """
  @spec circuit_breaker_events() :: [event()]
  def circuit_breaker_events do
    [
      [:snakepit, :circuit_breaker, :opened],
      [:snakepit, :circuit_breaker, :closed],
      [:snakepit, :circuit_breaker, :half_open],
      [:snakepit, :circuit_breaker, :call, :allowed],
      [:snakepit, :circuit_breaker, :call, :rejected],
      [:snakepit, :circuit_breaker, :call, :success],
      [:snakepit, :circuit_breaker, :call, :failure]
    ]
  end

  @doc """
  Returns all exception/error telemetry events.
  """
  @spec exception_events() :: [event()]
  def exception_events do
    [
      [:snakepit, :error, :shape_mismatch],
      [:snakepit, :error, :device],
      [:snakepit, :error, :oom],
      [:snakepit, :error, :dtype_mismatch],
      [:snakepit, :error, :dimension_error],
      [:snakepit, :error, :python_exception]
    ]
  end

  @doc """
  Returns all GPU profiler telemetry events.
  """
  @spec gpu_profiler_events() :: [event()]
  def gpu_profiler_events do
    [
      [:snakepit, :gpu, :memory, :sampled],
      [:snakepit, :gpu, :utilization, :sampled],
      [:snakepit, :gpu, :temperature, :sampled],
      [:snakepit, :gpu, :power, :sampled]
    ]
  end

  @doc """
  Returns all retry/backoff telemetry events.
  """
  @spec retry_events() :: [event()]
  def retry_events do
    [
      [:snakepit, :retry, :attempt],
      [:snakepit, :retry, :success],
      [:snakepit, :retry, :exhausted],
      [:snakepit, :retry, :backoff]
    ]
  end

  @doc """
  Returns all ML-related telemetry events.

  This combines hardware, circuit breaker, exception, GPU profiler,
  and retry events.
  """
  @spec all_ml_events() :: [event()]
  def all_ml_events do
    hardware_events() ++
      circuit_breaker_events() ++
      exception_events() ++
      gpu_profiler_events() ++
      retry_events()
  end

  @doc """
  Returns the schema for a given event.

  Returns nil for unknown events.
  """
  @spec event_schema(event()) :: schema() | nil
  def event_schema(event) do
    Map.get(schemas(), event)
  end

  @spec schemas() :: %{event() => schema()}
  defp schemas do
    %{
      # Hardware events
      [:snakepit, :hardware, :detect, :start] => %{
        measurements: %{system_time: :system_time},
        metadata: %{}
      },
      [:snakepit, :hardware, :detect, :stop] => %{
        measurements: %{duration: :monotonic_time},
        metadata: %{accelerator: :atom, platform: :string}
      },
      [:snakepit, :hardware, :select, :start] => %{
        measurements: %{system_time: :system_time},
        metadata: %{preference: :any}
      },
      [:snakepit, :hardware, :select, :stop] => %{
        measurements: %{duration: :monotonic_time},
        metadata: %{device: :any, success: :atom}
      },
      [:snakepit, :hardware, :cache, :hit] => %{
        measurements: %{},
        metadata: %{key: :atom}
      },
      [:snakepit, :hardware, :cache, :miss] => %{
        measurements: %{},
        metadata: %{key: :atom}
      },

      # Circuit breaker events
      [:snakepit, :circuit_breaker, :opened] => %{
        measurements: %{failure_count: :integer},
        metadata: %{pool: :atom, reason: :atom}
      },
      [:snakepit, :circuit_breaker, :closed] => %{
        measurements: %{},
        metadata: %{pool: :atom}
      },
      [:snakepit, :circuit_breaker, :half_open] => %{
        measurements: %{},
        metadata: %{pool: :atom}
      },
      [:snakepit, :circuit_breaker, :call, :allowed] => %{
        measurements: %{},
        metadata: %{pool: :atom, state: :atom}
      },
      [:snakepit, :circuit_breaker, :call, :rejected] => %{
        measurements: %{},
        metadata: %{pool: :atom, state: :atom}
      },
      [:snakepit, :circuit_breaker, :call, :success] => %{
        measurements: %{duration: :monotonic_time},
        metadata: %{pool: :atom}
      },
      [:snakepit, :circuit_breaker, :call, :failure] => %{
        measurements: %{duration: :monotonic_time},
        metadata: %{pool: :atom, error: :any}
      },

      # Exception events
      [:snakepit, :error, :shape_mismatch] => %{
        measurements: %{},
        metadata: %{
          expected: :list,
          got: :list,
          dimension: :integer,
          operation: :string
        }
      },
      [:snakepit, :error, :device] => %{
        measurements: %{},
        metadata: %{
          expected_device: :any,
          actual_device: :any,
          operation: :string
        }
      },
      [:snakepit, :error, :oom] => %{
        measurements: %{
          requested_bytes: :integer,
          available_bytes: :integer
        },
        metadata: %{device: :any, operation: :string}
      },
      [:snakepit, :error, :dtype_mismatch] => %{
        measurements: %{},
        metadata: %{expected: :atom, got: :atom}
      },
      [:snakepit, :error, :dimension_error] => %{
        measurements: %{},
        metadata: %{expected_dims: :integer, got_dims: :integer}
      },
      [:snakepit, :error, :python_exception] => %{
        measurements: %{},
        metadata: %{type: :string, message: :string, traceback: :string}
      },

      # GPU profiler events
      [:snakepit, :gpu, :memory, :sampled] => %{
        measurements: %{
          used_mb: :integer,
          total_mb: :integer,
          free_mb: :integer
        },
        metadata: %{device: :any, utilization: :float}
      },
      [:snakepit, :gpu, :utilization, :sampled] => %{
        measurements: %{gpu_percent: :float, memory_percent: :float},
        metadata: %{device: :any}
      },
      [:snakepit, :gpu, :temperature, :sampled] => %{
        measurements: %{celsius: :float},
        metadata: %{device: :any}
      },
      [:snakepit, :gpu, :power, :sampled] => %{
        measurements: %{watts: :float, limit_watts: :float},
        metadata: %{device: :any}
      },

      # Retry events
      [:snakepit, :retry, :attempt] => %{
        measurements: %{attempt: :integer, delay_ms: :integer},
        metadata: %{pool: :atom, operation: :any}
      },
      [:snakepit, :retry, :success] => %{
        measurements: %{attempts: :integer, total_duration: :monotonic_time},
        metadata: %{pool: :atom}
      },
      [:snakepit, :retry, :exhausted] => %{
        measurements: %{attempts: :integer, total_duration: :monotonic_time},
        metadata: %{pool: :atom, last_error: :any}
      },
      [:snakepit, :retry, :backoff] => %{
        measurements: %{delay_ms: :integer},
        metadata: %{pool: :atom, attempt: :integer}
      }
    }
  end
end
