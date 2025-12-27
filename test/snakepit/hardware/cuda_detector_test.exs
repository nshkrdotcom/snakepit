defmodule Snakepit.Hardware.CUDADetectorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware.CUDADetector

  describe "detect/0" do
    test "returns nil or cuda info map" do
      result = CUDADetector.detect()

      case result do
        nil ->
          # CUDA not available - this is expected in most CI environments
          assert true

        info when is_map(info) ->
          # CUDA is available - verify structure
          assert Map.has_key?(info, :version)
          assert Map.has_key?(info, :driver_version)
          assert Map.has_key?(info, :devices)
          assert is_list(info.devices)
      end
    end

    test "devices have required fields when cuda available" do
      result = CUDADetector.detect()

      case result do
        nil ->
          # CUDA not available - skip
          assert true

        %{devices: devices} ->
          Enum.each(devices, fn device ->
            assert Map.has_key?(device, :id)
            assert Map.has_key?(device, :name)
            assert Map.has_key?(device, :memory_total_mb)
            assert Map.has_key?(device, :memory_free_mb)
            assert is_integer(device.id)
            assert is_binary(device.name)
          end)
      end
    end

    test "version string follows expected format when cuda available" do
      result = CUDADetector.detect()

      case result do
        nil ->
          assert true

        %{version: version} ->
          # CUDA version like "12.1" or "11.8"
          assert is_binary(version)
          assert Regex.match?(~r/^\d+\.\d+/, version)
      end
    end
  end
end
