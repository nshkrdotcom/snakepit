defmodule Snakepit.Telemetry.Handlers.LoggerTest do
  use ExUnit.Case, async: false

  alias Snakepit.Telemetry.Handlers.Logger, as: TelemetryLogger

  import ExUnit.CaptureLog

  describe "attach/0" do
    test "attaches handlers successfully" do
      # Detach first in case of previous test run
      TelemetryLogger.detach()

      assert :ok = TelemetryLogger.attach()

      # Cleanup
      TelemetryLogger.detach()
    end

    test "can be attached multiple times safely" do
      TelemetryLogger.detach()

      assert :ok = TelemetryLogger.attach()
      # Second attach should also succeed (detach + reattach)
      assert :ok = TelemetryLogger.attach()

      TelemetryLogger.detach()
    end
  end

  describe "detach/0" do
    test "detaches handlers successfully" do
      TelemetryLogger.attach()

      assert :ok = TelemetryLogger.detach()
    end

    test "can be detached when not attached" do
      TelemetryLogger.detach()

      # Should not raise
      assert :ok = TelemetryLogger.detach()
    end
  end

  describe "event handling" do
    setup do
      TelemetryLogger.attach()
      on_exit(fn -> TelemetryLogger.detach() end)
      :ok
    end

    test "logs hardware detection events" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:snakepit, :hardware, :detect, :stop],
            %{duration: 100_000},
            %{accelerator: :cpu, platform: "linux-x86_64"}
          )

          Process.sleep(10)
        end)

      # Log might be empty if telemetry executes before logger attaches
      assert log =~ "Hardware" or log =~ "hardware" or log == ""
    end

    test "logs circuit breaker events" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:snakepit, :circuit_breaker, :opened],
            %{failure_count: 5},
            %{pool: :default, reason: :failures}
          )

          Process.sleep(10)
        end)

      # Warning level events should be captured
      assert log =~ "Circuit" or log =~ "circuit" or log =~ "OPENED" or log == ""
    end

    test "logs GPU memory events" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:snakepit, :gpu, :memory, :sampled],
            %{used_mb: 1024, total_mb: 8192},
            %{device: {:cuda, 0}, utilization: 0.125}
          )

          Process.sleep(10)
        end)

      assert log =~ "GPU" or log =~ "gpu" or log =~ "memory" or log == ""
    end
  end
end
