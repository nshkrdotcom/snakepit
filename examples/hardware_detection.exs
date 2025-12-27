#!/usr/bin/env elixir

# Hardware Detection Example
# Demonstrates automatic hardware detection for ML workloads including
# CPU, NVIDIA CUDA, Apple MPS, and AMD ROCm accelerators.
#
# Usage: mix run examples/hardware_detection.exs

Code.require_file("mix_bootstrap.exs", __DIR__)

Snakepit.Examples.Bootstrap.ensure_mix!([
  {:snakepit, path: "."}
])

defmodule HardwareDetectionExample do
  @moduledoc """
  Demonstrates Snakepit's hardware detection capabilities for ML workloads.
  """

  alias Snakepit.Hardware
  alias Snakepit.Hardware.Selector

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Hardware Detection for ML Workloads")
    IO.puts(String.duplicate("=", 60) <> "\n")

    demo_basic_detection()
    demo_capabilities()
    demo_device_selection()
    demo_fallback_strategy()
    demo_hardware_identity()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Hardware Detection Complete!")
    IO.puts(String.duplicate("=", 60) <> "\n")
  end

  defp demo_basic_detection do
    IO.puts("1. Basic Hardware Detection")
    IO.puts(String.duplicate("-", 40))

    info = Hardware.detect()

    IO.puts("   Platform: #{info.platform}")
    IO.puts("   Primary Accelerator: #{info.accelerator}")

    # CPU info
    IO.puts("\n   CPU Information:")
    IO.puts("   - Cores: #{info.cpu.cores}")
    IO.puts("   - Threads: #{info.cpu.threads}")
    IO.puts("   - Model: #{info.cpu.model}")
    IO.puts("   - Memory: #{info.cpu.memory_total_mb} MB")

    if info.cpu.features != [] do
      features = Enum.take(info.cpu.features, 5) |> Enum.join(", ")
      IO.puts("   - Features: #{features}...")
    end

    # CUDA info if available
    if info.cuda do
      IO.puts("\n   CUDA Information:")
      IO.puts("   - Version: #{info.cuda.version || "N/A"}")
      IO.puts("   - Driver: #{info.cuda.driver_version || "N/A"}")
      IO.puts("   - Devices: #{length(info.cuda.devices)}")

      for device <- info.cuda.devices do
        IO.puts("     Device #{device.id}: #{device.name}")
        IO.puts("       Memory: #{device.memory_total_mb} MB (#{device.memory_free_mb} MB free)")
        IO.puts("       Compute: #{device.compute_capability}")
      end
    else
      IO.puts("\n   CUDA: Not available")
    end

    # MPS info if available (macOS)
    case info.mps do
      nil ->
        IO.puts("   MPS: Not available")

      false ->
        IO.puts("   MPS: Not available")

      mps_info when is_map(mps_info) ->
        IO.puts("\n   MPS Information:")
        IO.puts("   - Available: #{mps_info.available}")
    end

    # ROCm info if available
    if info.rocm do
      IO.puts("\n   ROCm Information:")
      IO.puts("   - Devices: #{length(info.rocm.devices)}")
    else
      IO.puts("   ROCm: Not available")
    end

    IO.puts("")
  end

  defp demo_capabilities do
    IO.puts("2. Capability Flags")
    IO.puts(String.duplicate("-", 40))

    caps = Hardware.capabilities()

    IO.puts("   Accelerators:")
    IO.puts("   - CUDA: #{caps.cuda}")
    IO.puts("   - MPS: #{caps.mps}")
    IO.puts("   - ROCm: #{caps.rocm}")

    IO.puts("\n   CPU Features:")
    IO.puts("   - AVX: #{caps.avx}")
    IO.puts("   - AVX2: #{caps.avx2}")
    IO.puts("   - AVX-512: #{caps.avx512}")

    if caps.cuda do
      IO.puts("\n   CUDA Capabilities:")
      IO.puts("   - Version: #{caps.cuda_version}")
      IO.puts("   - cuDNN: #{caps.cudnn}")

      if caps.cudnn do
        IO.puts("   - cuDNN Version: #{caps.cudnn_version}")
      end
    end

    IO.puts("")
  end

  defp demo_device_selection do
    IO.puts("3. Device Selection")
    IO.puts(String.duplicate("-", 40))

    # Auto selection
    case Selector.select(:auto) do
      {:ok, device} ->
        IO.puts("   Auto-selected device: #{format_device(device)}")

      {:error, reason} ->
        IO.puts("   Auto-selection failed: #{reason}")
    end

    # CPU is always available
    case Selector.select(:cpu) do
      {:ok, :cpu} ->
        IO.puts("   CPU selection: Success (always available)")

      {:error, reason} ->
        IO.puts("   CPU selection failed: #{reason}")
    end

    # Try CUDA selection
    case Selector.select(:cuda) do
      {:ok, device} ->
        IO.puts("   CUDA selection: #{format_device(device)}")

      {:error, :device_not_available} ->
        IO.puts("   CUDA selection: Not available (expected on systems without NVIDIA GPU)")
    end

    # Try specific CUDA device
    case Selector.select({:cuda, 0}) do
      {:ok, device} ->
        IO.puts("   CUDA device 0: #{format_device(device)}")

      {:error, :device_not_available} ->
        IO.puts("   CUDA device 0: Not available")
    end

    # Try MPS selection (macOS only)
    case Selector.select(:mps) do
      {:ok, :mps} ->
        IO.puts("   MPS selection: Available")

      {:error, :device_not_available} ->
        IO.puts("   MPS selection: Not available (expected on non-macOS)")
    end

    IO.puts("")
  end

  defp demo_fallback_strategy do
    IO.puts("4. Fallback Strategy")
    IO.puts(String.duplicate("-", 40))

    # Prefer GPU, fallback to CPU
    preferences = [:cuda, :mps, :rocm, :cpu]

    case Selector.select_with_fallback(preferences) do
      {:ok, device} ->
        IO.puts("   Preference list: #{inspect(preferences)}")
        IO.puts("   Selected device: #{format_device(device)}")

      {:error, :no_device} ->
        IO.puts("   No device available from preference list")
    end

    # GPU-only preference (may fail)
    gpu_only = [:cuda, :mps, :rocm]

    case Selector.select_with_fallback(gpu_only) do
      {:ok, device} ->
        IO.puts("\n   GPU-only preferences: #{inspect(gpu_only)}")
        IO.puts("   Selected device: #{format_device(device)}")

      {:error, :no_device} ->
        IO.puts("\n   GPU-only preferences: #{inspect(gpu_only)}")
        IO.puts("   No GPU available (falling back to CPU recommended)")
    end

    IO.puts("")
  end

  defp demo_hardware_identity do
    IO.puts("5. Hardware Identity (for lock files)")
    IO.puts(String.duplicate("-", 40))

    identity = Hardware.identity()

    IO.puts("   Identity Map:")
    IO.puts("   - Platform: #{identity["platform"]}")
    IO.puts("   - Accelerator: #{identity["accelerator"]}")
    IO.puts("   - GPU Count: #{identity["gpu_count"]}")

    if identity["cpu_features"] do
      features = Enum.take(identity["cpu_features"], 3) |> Enum.join(", ")
      IO.puts("   - CPU Features: #{features}...")
    end

    IO.puts("\n   This identity can be saved to a lock file for reproducible environments.")
    IO.puts("   Example: File.write!(\"hardware.lock\", Jason.encode!(identity))")
    IO.puts("")
  end

  defp format_device(:cpu), do: "CPU"
  defp format_device(:mps), do: "MPS (Apple Metal)"
  defp format_device(:rocm), do: "ROCm (AMD)"
  defp format_device({:cuda, id}), do: "CUDA device #{id}"
  defp format_device(other), do: inspect(other)
end

# Run the example (no pool needed - these are local Elixir operations)
HardwareDetectionExample.run()
