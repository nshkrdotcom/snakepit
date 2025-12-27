defmodule Snakepit.HardwareTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware

  describe "detect/0" do
    test "returns hardware info map with required keys" do
      info = Hardware.detect()

      assert is_map(info)
      assert Map.has_key?(info, :accelerator)
      assert Map.has_key?(info, :cpu)
      assert Map.has_key?(info, :platform)
      assert info.accelerator in [:cpu, :cuda, :mps, :rocm]
    end

    test "cpu info has required fields" do
      info = Hardware.detect()

      assert is_map(info.cpu)
      assert is_integer(info.cpu.cores) and info.cpu.cores > 0
      assert is_integer(info.cpu.threads) and info.cpu.threads > 0
      assert is_binary(info.cpu.model)
      assert is_list(info.cpu.features)
      assert is_integer(info.cpu.memory_total_mb)
    end

    test "platform string matches expected format" do
      info = Hardware.detect()

      assert is_binary(info.platform)
      # Platform should be like "linux-x86_64" or "macos-arm64"
      assert String.contains?(info.platform, "-")
    end
  end

  describe "info/0" do
    test "returns same result as detect/0" do
      info1 = Hardware.detect()
      info2 = Hardware.info()

      assert info1.accelerator == info2.accelerator
      assert info1.platform == info2.platform
    end
  end

  describe "capabilities/0" do
    test "returns capability flags map" do
      caps = Hardware.capabilities()

      assert is_map(caps)
      assert is_boolean(caps.cuda)
      assert is_boolean(caps.mps)
      assert is_boolean(caps.rocm)
      assert is_boolean(caps.avx)
      assert is_boolean(caps.avx2)
    end

    test "cuda_version is string or nil" do
      caps = Hardware.capabilities()

      assert is_nil(caps.cuda_version) or is_binary(caps.cuda_version)
    end
  end

  describe "select/1" do
    test "select :cpu always succeeds" do
      assert {:ok, :cpu} = Hardware.select(:cpu)
    end

    test "select :auto returns available device" do
      {:ok, device} = Hardware.select(:auto)
      assert device in [:cpu, :cuda, :mps, :rocm, {:cuda, 0}]
    end

    test "select unavailable device returns error" do
      # This test assumes CUDA is not available in CI
      # Skip if CUDA is actually available
      caps = Hardware.capabilities()

      if not caps.cuda do
        assert {:error, :device_not_available} = Hardware.select(:cuda)
      end
    end
  end

  describe "select_with_fallback/1" do
    test "falls back through preference list" do
      # With [:cuda, :mps, :cpu], should always succeed since cpu is in list
      assert {:ok, device} = Hardware.select_with_fallback([:cuda, :mps, :cpu])
      assert device in [:cpu, :cuda, :mps, {:cuda, 0}]
    end

    test "returns error when no device available" do
      # Empty list should fail
      assert {:error, :no_device} = Hardware.select_with_fallback([])
    end
  end

  describe "identity/0" do
    test "returns identity map for lock files" do
      identity = Hardware.identity()

      assert is_map(identity)
      assert is_binary(identity["platform"])
      assert is_binary(identity["accelerator"])
      assert is_list(identity["cpu_features"])
      assert is_integer(identity["gpu_count"])
    end

    test "cpu_features are strings" do
      identity = Hardware.identity()

      Enum.each(identity["cpu_features"], fn feature ->
        assert is_binary(feature)
      end)
    end
  end

  describe "clear_cache/0" do
    test "clears cached hardware info" do
      # First call populates cache
      _info1 = Hardware.detect()

      # Clear cache
      assert :ok = Hardware.clear_cache()

      # Should still work after clearing
      info2 = Hardware.detect()
      assert is_map(info2)
    end
  end
end
