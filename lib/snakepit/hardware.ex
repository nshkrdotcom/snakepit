defmodule Snakepit.Hardware do
  @moduledoc """
  Hardware abstraction layer for Snakepit.

  Provides unified hardware detection and device selection for ML workloads.
  Supports CPU, NVIDIA CUDA, Apple MPS, and AMD ROCm accelerators.

  ## Features

  - **Automatic Detection**: Detects available hardware at startup
  - **Device Selection**: Intelligent device selection with fallback strategies
  - **Caching**: Results are cached for performance
  - **Lock File Support**: Identity map for lock file generation

  ## Usage

      # Detect all hardware
      info = Snakepit.Hardware.detect()
      # => %{accelerator: :cuda, cpu: %{...}, cuda: %{...}, ...}

      # Check capabilities
      caps = Snakepit.Hardware.capabilities()
      # => %{cuda: true, mps: false, avx2: true, ...}

      # Select device
      {:ok, device} = Snakepit.Hardware.select(:auto)
      # => {:ok, {:cuda, 0}}

      # Select with fallback
      {:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])
      # => {:ok, :cpu}

  ## Identity Map

  The `identity/0` function returns a map suitable for lock file generation:

      identity = Snakepit.Hardware.identity()
      # => %{"platform" => "linux-x86_64", "accelerator" => "cuda", ...}

  This can be serialized to JSON/YAML for lock files that need to track
  the hardware environment.
  """

  alias Snakepit.Hardware.{Detector, Selector}

  @type device :: Selector.device()
  @type device_preference :: Selector.device_preference()
  @type hardware_info :: Detector.hardware_info()
  @type capabilities :: Detector.capabilities()

  @doc """
  Detects all hardware information.

  Returns a map with:
  - `:accelerator` - Primary accelerator type (`:cpu`, `:cuda`, `:mps`, `:rocm`)
  - `:cpu` - CPU information (cores, threads, model, features, memory)
  - `:cuda` - NVIDIA CUDA info or nil
  - `:mps` - Apple MPS info or nil
  - `:rocm` - AMD ROCm info or nil
  - `:platform` - Platform string (e.g., "linux-x86_64")

  ## Examples

      info = Snakepit.Hardware.detect()
      info.accelerator
      #=> :cuda

      info.cpu.cores
      #=> 8
  """
  @spec detect() :: hardware_info()
  defdelegate detect(), to: Detector

  @doc """
  Alias for `detect/0`.

  Returns the same hardware info map as detect/0.
  """
  @spec info() :: hardware_info()
  def info, do: detect()

  @doc """
  Returns hardware capability flags.

  Returns a map of boolean flags for quick feature checks:
  - `:cuda` - CUDA available
  - `:mps` - Apple MPS available
  - `:rocm` - AMD ROCm available
  - `:avx` - AVX instruction set available
  - `:avx2` - AVX2 instruction set available
  - `:avx512` - AVX-512 instruction set available
  - `:cuda_version` - CUDA version string or nil
  - `:cudnn_version` - cuDNN version string or nil
  - `:cudnn` - cuDNN available

  ## Examples

      caps = Snakepit.Hardware.capabilities()
      if caps.cuda do
        cuda_version = caps.cuda_version
      end
  """
  @spec capabilities() :: capabilities()
  defdelegate capabilities(), to: Detector

  @doc """
  Clears the hardware detection cache.

  Forces re-detection on next call. Useful after hardware changes
  or for testing.

  ## Examples

      Snakepit.Hardware.clear_cache()
      :ok
  """
  @spec clear_cache() :: :ok
  defdelegate clear_cache(), to: Detector

  @doc """
  Selects a device based on preference.

  ## Options

  - `:auto` - Automatically select best available accelerator
  - `:cpu` - Select CPU (always available)
  - `:cuda` - Select CUDA (fails if not available)
  - `:mps` - Select MPS (fails if not macOS with Apple Silicon)
  - `:rocm` - Select ROCm (fails if not available)
  - `{:cuda, device_id}` - Select specific CUDA device by ID

  ## Returns

  - `{:ok, device}` on success
  - `{:error, :device_not_available}` if requested device is unavailable

  ## Examples

      # Auto-select best device
      {:ok, device} = Snakepit.Hardware.select(:auto)

      # Request specific device
      case Snakepit.Hardware.select(:cuda) do
        {:ok, {:cuda, 0}} -> :ok
        {:error, :device_not_available} -> :error
      end
  """
  @spec select(device_preference()) :: {:ok, device()} | {:error, :device_not_available}
  defdelegate select(preference), to: Selector

  @doc """
  Selects the first available device from a preference list.

  Tries each device in order until one is available. This is useful
  for graceful degradation strategies.

  ## Examples

      # Prefer CUDA, fall back to MPS, then CPU
      {:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])

      # Returns :cpu if CUDA and MPS are unavailable
  """
  @spec select_with_fallback([device_preference()]) :: {:ok, device()} | {:error, :no_device}
  defdelegate select_with_fallback(preferences), to: Selector

  @doc """
  Returns device information for a selected device.

  Returns a map with device-specific details useful for logging,
  telemetry, and diagnostics.

  ## Examples

      info = Snakepit.Hardware.device_info({:cuda, 0})
      # => %{type: :cuda, device_id: 0, name: "NVIDIA GeForce RTX 3080", ...}
  """
  @spec device_info(device()) :: map()
  defdelegate device_info(device), to: Selector

  @doc """
  Returns a hardware identity map for lock files.

  The identity map contains string keys and is suitable for
  serialization to JSON/YAML lock files that need to track
  the hardware environment.

  ## Keys

  - `"platform"` - Platform string (e.g., "linux-x86_64")
  - `"accelerator"` - Primary accelerator type as string
  - `"cpu_features"` - List of CPU feature strings
  - `"gpu_count"` - Number of GPUs detected

  ## Examples

      identity = Snakepit.Hardware.identity()
      Jason.encode!(identity)
      # => "{\\"platform\\":\\"linux-x86_64\\",\\"accelerator\\":\\"cuda\\",...}"
  """
  @spec identity() :: map()
  def identity do
    info = detect()

    gpu_count =
      cond do
        info.cuda != nil -> length(info.cuda.devices)
        info.rocm != nil -> length(info.rocm.devices)
        info.mps != nil and info.mps.available -> 1
        true -> 0
      end

    cpu_features =
      info.cpu.features
      |> Enum.map(&Atom.to_string/1)

    %{
      "platform" => info.platform,
      "accelerator" => Atom.to_string(info.accelerator),
      "cpu_features" => cpu_features,
      "gpu_count" => gpu_count
    }
  end
end
