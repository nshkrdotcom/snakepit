defmodule Snakepit.Hardware.Detector do
  @moduledoc """
  Unified hardware detection module.

  Aggregates CPU, CUDA, MPS, and ROCm detection into a single hardware info structure.
  Results are cached in ETS for performance.
  """

  alias Snakepit.Hardware.{CPUDetector, CUDADetector, MPSDetector, ROCmDetector}

  @hardware_info_key {__MODULE__, :hardware_info}
  @capabilities_key {__MODULE__, :capabilities}
  @cache_miss :snakepit_cache_miss

  @type accelerator :: :cpu | :cuda | :mps | :rocm

  @type hardware_info :: %{
          accelerator: accelerator(),
          cpu: CPUDetector.cpu_info(),
          cuda: CUDADetector.cuda_info() | nil,
          mps: MPSDetector.mps_info() | nil,
          rocm: ROCmDetector.rocm_info() | nil,
          platform: String.t()
        }

  @type capabilities :: %{
          cuda: boolean(),
          mps: boolean(),
          rocm: boolean(),
          avx: boolean(),
          avx2: boolean(),
          avx512: boolean(),
          cuda_version: String.t() | nil,
          cudnn_version: String.t() | nil,
          cudnn: boolean()
        }

  @doc """
  Detects all hardware information.

  Returns a map with aggregated hardware info from all detectors.
  Results are cached for performance.
  """
  @spec detect() :: hardware_info()
  def detect do
    fetch_cached(@hardware_info_key, &do_detect/0)
  end

  @doc """
  Returns hardware capability flags.

  Returns a map of boolean capability flags for quick feature checks.
  """
  @spec capabilities() :: capabilities()
  def capabilities do
    fetch_cached(@capabilities_key, fn ->
      detect()
      |> build_capabilities()
    end)
  end

  @doc """
  Clears the hardware detection cache.

  Forces re-detection on next call to detect/0 or capabilities/0.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@hardware_info_key)
    :persistent_term.erase(@capabilities_key)
    :ok
  end

  @spec do_detect() :: hardware_info()
  defp do_detect do
    cpu = CPUDetector.detect()
    cuda = CUDADetector.detect()
    mps = MPSDetector.detect()
    rocm = ROCmDetector.detect()

    accelerator = determine_accelerator(cuda, mps, rocm)
    platform = build_platform_string()

    %{
      accelerator: accelerator,
      cpu: cpu,
      cuda: cuda,
      mps: mps,
      rocm: rocm,
      platform: platform
    }
  end

  @spec determine_accelerator(
          CUDADetector.cuda_info() | nil,
          MPSDetector.mps_info() | nil,
          ROCmDetector.rocm_info() | nil
        ) :: accelerator()
  defp determine_accelerator(cuda, mps, rocm) do
    cond do
      cuda != nil and cuda.devices != [] -> :cuda
      mps != nil and mps.available -> :mps
      rocm != nil and rocm.devices != [] -> :rocm
      true -> :cpu
    end
  end

  @spec build_platform_string() :: String.t()
  defp build_platform_string do
    os = os_name()
    arch = arch_name()
    "#{os}-#{arch}"
  end

  defp os_name do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "macos"
      {:win32, _} -> "windows"
      _ -> "unknown"
    end
  end

  defp arch_name do
    # :system_architecture always returns a charlist
    arch = :erlang.system_info(:system_architecture)
    arch_str = List.to_string(arch)
    normalize_arch(arch_str)
  end

  defp normalize_arch(arch_str) do
    arch_lower = String.downcase(arch_str)

    cond do
      String.contains?(arch_lower, "x86_64") or String.contains?(arch_lower, "amd64") ->
        "x86_64"

      String.contains?(arch_lower, "aarch64") or String.contains?(arch_lower, "arm64") ->
        "arm64"

      String.contains?(arch_lower, "arm") ->
        "arm"

      true ->
        arch_str
    end
  end

  @spec build_capabilities(hardware_info()) :: capabilities()
  defp build_capabilities(info) do
    cpu_features = info.cpu.features

    %{
      cuda: info.cuda != nil and info.cuda.devices != [],
      mps: info.mps != nil and info.mps.available,
      rocm: info.rocm != nil and info.rocm.devices != [],
      avx: :avx in cpu_features,
      avx2: :avx2 in cpu_features,
      avx512: :avx512 in cpu_features,
      cuda_version: get_in(info, [:cuda, :version]),
      cudnn_version: get_in(info, [:cuda, :cudnn_version]),
      cudnn: get_in(info, [:cuda, :cudnn_version]) != nil
    }
  end

  @spec fetch_cached(term(), (-> term())) :: term()
  defp fetch_cached(key, fun) do
    case :persistent_term.get(key, @cache_miss) do
      @cache_miss ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
