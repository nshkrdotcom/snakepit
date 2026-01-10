defmodule Snakepit.Error.DeviceTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error.Device

  describe "device_mismatch/3" do
    test "creates device mismatch error" do
      error = Device.device_mismatch(:cpu, {:cuda, 0}, "matmul")

      assert %Snakepit.Error.DeviceMismatch{} = error
      assert error.expected == :cpu
      assert error.got == {:cuda, 0}
      assert error.operation == "matmul"
    end

    test "includes helpful message" do
      error = Device.device_mismatch(:mps, :cpu, "add")

      message = Exception.message(error)
      assert message =~ "device" or message =~ "Device"
    end
  end

  describe "out_of_memory/3" do
    test "creates OOM error with memory info" do
      error = Device.out_of_memory({:cuda, 0}, 1024 * 1024 * 1024, 512 * 1024 * 1024)

      assert %Snakepit.Error.OutOfMemory{} = error
      assert error.device == {:cuda, 0}
      assert error.requested_bytes == 1024 * 1024 * 1024
      assert error.available_bytes == 512 * 1024 * 1024
    end

    test "includes human-readable memory values" do
      error = Device.out_of_memory({:cuda, 0}, 2_147_483_648, 1_073_741_824)

      message = Exception.message(error)
      # Should show MB or GB values
      assert message =~ "GB" or message =~ "MB" or message =~ "memory" or message =~ "OOM"
    end

    test "includes recovery suggestions" do
      error = Device.out_of_memory({:cuda, 0}, 1024 * 1024 * 1024, 512 * 1024 * 1024)

      assert is_list(error.suggestions)
      assert [_ | _] = error.suggestions
    end
  end

  describe "device_unavailable/2" do
    test "creates device unavailable error" do
      error = Device.device_unavailable({:cuda, 2}, "matrix_multiply")

      assert %Snakepit.Error.DeviceMismatch{} = error
      assert error.message =~ "unavailable" or error.message =~ "not found"
    end
  end

  describe "Exception protocol" do
    test "DeviceMismatch implements Exception" do
      error = Device.device_mismatch(:cpu, {:cuda, 0}, "op")

      message = Exception.message(error)
      assert is_binary(message)
    end

    test "OutOfMemory implements Exception" do
      error = Device.out_of_memory({:cuda, 0}, 1024, 512)

      message = Exception.message(error)
      assert is_binary(message)
    end
  end

  describe "telemetry emission" do
    test "emits telemetry event on OOM" do
      parent = self()
      ref = make_ref()
      operation = "oom-test-#{inspect(ref)}"

      :telemetry.attach(
        "oom-test-#{inspect(ref)}",
        [:snakepit, :error, :oom],
        fn _event, measurements, metadata, _config ->
          if metadata.operation == operation do
            send(parent, {:telemetry, measurements, metadata})
          end
        end,
        nil
      )

      _error = Device.out_of_memory({:cuda, 0}, 1024, 512, operation)

      assert_receive {:telemetry, measurements, metadata}
      assert measurements.requested_bytes == 1024
      assert measurements.available_bytes == 512
      assert metadata.device == {:cuda, 0}

      :telemetry.detach("oom-test-#{inspect(ref)}")
    end
  end
end
