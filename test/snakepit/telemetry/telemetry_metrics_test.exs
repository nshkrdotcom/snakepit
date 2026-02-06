defmodule Snakepit.TelemetryMetricsTest do
  use ExUnit.Case, async: false

  alias Telemetry.Metrics.{Counter, LastValue, Summary}
  alias Snakepit.TelemetryMetrics

  test "defines heartbeat metric set with expected names and tags" do
    metrics = TelemetryMetrics.metrics()

    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :pings]}, &1))
    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :pongs]}, &1))
    assert Enum.any?(metrics, &match?(%Counter{name: [:snakepit, :heartbeat, :failures]}, &1))
    assert Enum.any?(metrics, &match?(%Summary{name: [:snakepit, :heartbeat, :latency]}, &1))
    assert Enum.any?(metrics, &match?(%LastValue{name: [:snakepit, :heartbeat, :missed]}, &1))

    Enum.each(metrics, fn metric ->
      assert metric.tags == nil or is_list(metric.tags)
    end)
  end

  test "reporter_children coerces string-key telemetry_metrics config safely" do
    previous = Application.get_env(:snakepit, :telemetry_metrics)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:snakepit, :telemetry_metrics)
      else
        Application.put_env(:snakepit, :telemetry_metrics, previous)
      end
    end)

    Application.put_env(:snakepit, :telemetry_metrics, %{
      "prometheus" => %{
        "enabled" => "true",
        "port" => "9570",
        "protocol" => "http"
      }
    })

    children = TelemetryMetrics.reporter_children()
    assert length(children) == 1
  end
end
