defmodule Snakepit.TelemetryMetricsTest do
  use ExUnit.Case, async: true

  alias Telemetry.Metrics.{Counter, LastValue, Summary}

  test "defines heartbeat metric set with expected names and tags" do
    metrics = Snakepit.TelemetryMetrics.metrics()

    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :pings]}, &1))
    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :pongs]}, &1))
    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :failures]}, &1))
    assert Enum.any?(metrics, &match?(%Summary{name: [:snakepit, :heartbeat, :latency]}, &1))
    assert Enum.any?(metrics, &match?(%LastValue{name: [:snakepit, :heartbeat, :missed]}, &1))

    Enum.each(metrics, fn metric ->
      assert metric.tags == nil or is_list(metric.tags)
    end)
  end
end
