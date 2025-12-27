defmodule Snakepit.Hardware.DetectorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware.Detector

  describe "detect/0" do
    test "returns complete hardware info" do
      info = Detector.detect()

      assert is_map(info)
      assert Map.has_key?(info, :accelerator)
      assert Map.has_key?(info, :cuda)
      assert Map.has_key?(info, :mps)
      assert Map.has_key?(info, :rocm)
      assert Map.has_key?(info, :cpu)
      assert Map.has_key?(info, :platform)
    end

    test "accelerator is valid type" do
      info = Detector.detect()

      assert info.accelerator in [:cpu, :cuda, :mps, :rocm]
    end

    test "platform follows expected pattern" do
      info = Detector.detect()

      assert is_binary(info.platform)

      # Should be like "linux-x86_64" or "macos-arm64"
      [os, arch] = String.split(info.platform, "-", parts: 2)
      assert os in ["linux", "macos", "windows", "unknown"]
      assert arch in ["x86_64", "arm64", "aarch64"] or is_binary(arch)
    end
  end

  describe "capabilities/0" do
    test "returns capability map with boolean flags" do
      caps = Detector.capabilities()

      assert is_map(caps)
      assert is_boolean(caps.cuda)
      assert is_boolean(caps.mps)
      assert is_boolean(caps.rocm)
      assert is_boolean(caps.avx)
      assert is_boolean(caps.avx2)
      assert is_boolean(caps.avx512)
    end

    test "version fields are nil or strings" do
      caps = Detector.capabilities()

      assert is_nil(caps.cuda_version) or is_binary(caps.cuda_version)
      assert is_nil(caps.cudnn_version) or is_binary(caps.cudnn_version)
    end

    test "cudnn requires cuda" do
      caps = Detector.capabilities()

      # If cudnn is available, cuda must also be available
      if caps.cudnn do
        assert caps.cuda
      end
    end
  end
end
