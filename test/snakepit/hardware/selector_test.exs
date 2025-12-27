defmodule Snakepit.Hardware.SelectorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware.{Detector, Selector}

  describe "select/1" do
    test "select :auto returns available accelerator" do
      {:ok, device} = Selector.select(:auto)

      assert device in [:cpu, :cuda, :mps, :rocm, {:cuda, 0}]
    end

    test "select :cpu always succeeds" do
      assert {:ok, :cpu} = Selector.select(:cpu)
    end

    test "select :cuda returns error when not available" do
      # Check if CUDA is available
      info = Detector.detect()

      case info.cuda do
        nil ->
          assert {:error, :device_not_available} = Selector.select(:cuda)

        %{devices: []} ->
          assert {:error, :device_not_available} = Selector.select(:cuda)

        %{devices: [_ | _] = _devices} ->
          assert {:ok, {:cuda, 0}} = Selector.select(:cuda)
      end
    end

    test "select {:cuda, device_id} validates device exists" do
      info = Detector.detect()

      case info.cuda do
        nil ->
          assert {:error, :device_not_available} = Selector.select({:cuda, 0})

        %{devices: []} ->
          assert {:error, :device_not_available} = Selector.select({:cuda, 0})

        %{devices: [_ | _] = devices} ->
          # First device should exist
          assert {:ok, {:cuda, 0}} = Selector.select({:cuda, 0})

          # Non-existent device should fail
          fake_id = Enum.count(devices) + 100
          assert {:error, :device_not_available} = Selector.select({:cuda, fake_id})
      end
    end

    test "select :mps returns error on non-macOS" do
      case :os.type() do
        {:unix, :darwin} ->
          # On macOS, result depends on hardware
          result = Selector.select(:mps)
          assert match?({:ok, :mps}, result) or match?({:error, :device_not_available}, result)

        _ ->
          # On non-macOS, should fail
          assert {:error, :device_not_available} = Selector.select(:mps)
      end
    end
  end

  describe "select_with_fallback/1" do
    test "returns first available device from list" do
      # Should fall back to :cpu if nothing else available
      assert {:ok, device} = Selector.select_with_fallback([:cuda, :mps, :cpu])
      assert device in [:cpu, :cuda, :mps, {:cuda, 0}]
    end

    test "returns error for empty preference list" do
      assert {:error, :no_device} = Selector.select_with_fallback([])
    end

    test "returns error when no devices in list are available" do
      # Create a list of definitely unavailable devices
      # Note: This assumes the test environment doesn't have ROCm
      info = Detector.detect()

      if is_nil(info.rocm) and is_nil(info.cuda) and is_nil(info.mps) do
        # Only ROCm in list should fail since ROCm is rarely available
        assert {:error, :no_device} = Selector.select_with_fallback([:rocm])
      end
    end

    test "prefers earlier devices in preference list" do
      # If we put :cpu first, it should return :cpu
      assert {:ok, :cpu} = Selector.select_with_fallback([:cpu, :cuda, :mps])
    end
  end
end
