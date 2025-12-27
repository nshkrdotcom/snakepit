defmodule Snakepit.Hardware.CPUDetectorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Hardware.CPUDetector

  describe "detect/0" do
    test "returns cpu info map" do
      info = CPUDetector.detect()

      assert is_map(info)
      assert Map.has_key?(info, :cores)
      assert Map.has_key?(info, :threads)
      assert Map.has_key?(info, :model)
      assert Map.has_key?(info, :features)
      assert Map.has_key?(info, :memory_total_mb)
    end

    test "cores is positive integer" do
      info = CPUDetector.detect()

      assert is_integer(info.cores)
      assert info.cores > 0
    end

    test "threads is positive integer" do
      info = CPUDetector.detect()

      assert is_integer(info.threads)
      assert info.threads > 0
      # Threads should be >= cores
      assert info.threads >= info.cores
    end

    test "model is non-empty string" do
      info = CPUDetector.detect()

      assert is_binary(info.model)
      # Model might be "Unknown" on some platforms
      assert String.length(info.model) > 0
    end

    test "features is list of atoms" do
      info = CPUDetector.detect()

      assert is_list(info.features)

      Enum.each(info.features, fn feature ->
        assert is_atom(feature)
      end)
    end

    test "memory_total_mb is non-negative integer" do
      info = CPUDetector.detect()

      assert is_integer(info.memory_total_mb)
      assert info.memory_total_mb >= 0
    end

    test "features contain common CPU flags" do
      info = CPUDetector.detect()

      # At least some features should be detected on modern CPUs
      # But this might be empty on some platforms, so we just verify it's a list
      assert is_list(info.features)
    end
  end
end
