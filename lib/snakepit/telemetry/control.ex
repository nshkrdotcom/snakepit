defmodule Snakepit.Telemetry.Control do
  @moduledoc """
  Helper functions for creating telemetry control messages.

  Control messages flow from Elixir to Python workers over the gRPC
  telemetry stream to adjust telemetry behavior at runtime.
  """

  alias Snakepit.Bridge.{
    TelemetryControl,
    TelemetryEventFilter,
    TelemetrySamplingUpdate,
    TelemetryToggle
  }

  @doc """
  Creates a control message to enable or disable telemetry.

  ## Examples

      iex> Snakepit.Telemetry.Control.toggle(true)
      %Snakepit.Bridge.TelemetryControl{
        control: {:toggle, %Snakepit.Bridge.TelemetryToggle{enabled: true}}
      }
  """
  def toggle(enabled) when is_boolean(enabled) do
    %TelemetryControl{
      control: {:toggle, %TelemetryToggle{enabled: enabled}}
    }
  end

  @doc """
  Creates a control message to adjust sampling rate.

  The sampling rate must be between 0.0 and 1.0, where:
  - 0.0 = no events emitted
  - 1.0 = all events emitted
  - 0.1 = 10% of events emitted

  Event patterns use glob-style matching (e.g., "python.*").

  ## Examples

      iex> Snakepit.Telemetry.Control.sampling(0.5)
      %Snakepit.Bridge.TelemetryControl{
        control: {:sampling, %Snakepit.Bridge.TelemetrySamplingUpdate{
          sampling_rate: 0.5,
          event_patterns: []
        }}
      }

      iex> Snakepit.Telemetry.Control.sampling(0.1, ["python.call.*"])
      %Snakepit.Bridge.TelemetryControl{
        control: {:sampling, %Snakepit.Bridge.TelemetrySamplingUpdate{
          sampling_rate: 0.1,
          event_patterns: ["python.call.*"]
        }}
      }
  """
  def sampling(rate, patterns \\ [])
      when is_number(rate) and rate >= 0.0 and rate <= 1.0 and is_list(patterns) do
    %TelemetryControl{
      control:
        {:sampling,
         %TelemetrySamplingUpdate{
           sampling_rate: rate,
           event_patterns: Enum.map(patterns, &to_string/1)
         }}
    }
  end

  @doc """
  Creates a control message to filter events.

  Allows explicit whitelisting or blacklisting of events.

  ## Examples

      iex> Snakepit.Telemetry.Control.filter(allow: ["python.call.start"])
      %Snakepit.Bridge.TelemetryControl{
        control: {:filter, %Snakepit.Bridge.TelemetryEventFilter{
          allow: ["python.call.start"],
          deny: []
        }}
      }

      iex> Snakepit.Telemetry.Control.filter(deny: ["python.memory.sampled"])
      %Snakepit.Bridge.TelemetryControl{
        control: {:filter, %Snakepit.Bridge.TelemetryEventFilter{
          allow: [],
          deny: ["python.memory.sampled"]
        }}
      }
  """
  def filter(opts \\ []) do
    allow = Keyword.get(opts, :allow, []) |> Enum.map(&to_string/1)
    deny = Keyword.get(opts, :deny, []) |> Enum.map(&to_string/1)

    %TelemetryControl{
      control:
        {:filter,
         %TelemetryEventFilter{
           allow: allow,
           deny: deny
         }}
    }
  end
end
