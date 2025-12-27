defmodule Snakepit.Telemetry.Handlers.MetricsTest do
  use ExUnit.Case, async: true

  alias Snakepit.Telemetry.Handlers.Metrics

  describe "definitions/0" do
    test "returns list of telemetry.metrics definitions" do
      defs = Metrics.definitions()

      assert is_list(defs)
      # Should have metrics for hardware, circuit breaker, etc.
      assert length(defs) > 5
    end

    test "metrics have valid types" do
      defs = Metrics.definitions()

      Enum.each(defs, fn metric ->
        assert metric.__struct__ in [
                 Telemetry.Metrics.Counter,
                 Telemetry.Metrics.Sum,
                 Telemetry.Metrics.Summary,
                 Telemetry.Metrics.LastValue,
                 Telemetry.Metrics.Distribution
               ]
      end)
    end

    test "includes hardware detection duration metric" do
      defs = Metrics.definitions()

      assert Enum.any?(defs, fn metric ->
               metric.event_name == [:snakepit, :hardware, :detect, :stop]
             end)
    end

    test "includes circuit breaker metrics" do
      defs = Metrics.definitions()

      assert Enum.any?(defs, fn metric ->
               match?([:snakepit, :circuit_breaker | _], metric.event_name)
             end)
    end

    test "includes GPU memory metric" do
      defs = Metrics.definitions()

      assert Enum.any?(defs, fn metric ->
               metric.event_name == [:snakepit, :gpu, :memory, :sampled]
             end)
    end
  end

  describe "prometheus_definitions/0" do
    test "returns prometheus-compatible metrics" do
      defs = Metrics.prometheus_definitions()

      assert is_list(defs)

      Enum.each(defs, fn metric ->
        # All metrics should have valid names for Prometheus
        assert is_atom(metric.name) or is_list(metric.name)
      end)
    end
  end
end
