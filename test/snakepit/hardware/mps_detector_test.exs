defmodule Snakepit.Hardware.MPSDetectorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware.MPSDetector

  describe "detect/0" do
    test "returns nil on non-macOS or mps info on macOS with Apple Silicon" do
      result = MPSDetector.detect()

      case :os.type() do
        {:unix, :darwin} ->
          # On macOS, might return MPS info or nil depending on hardware
          case result do
            nil ->
              # Intel Mac or MPS unavailable
              assert true

            info when is_map(info) ->
              assert Map.has_key?(info, :available)
              assert Map.has_key?(info, :device_name)
              assert Map.has_key?(info, :memory_total_mb)
              assert is_boolean(info.available)
              assert is_binary(info.device_name)
              assert is_integer(info.memory_total_mb)
          end

        _ ->
          # On non-macOS, should always return nil
          assert is_nil(result)
      end
    end

    test "returns nil on Linux" do
      case :os.type() do
        {:unix, :linux} ->
          assert is_nil(MPSDetector.detect())

        _ ->
          # Skip on other platforms
          assert true
      end
    end
  end
end
