# Hardware Abstraction Layer

## Overview

This document specifies Snakepit's hardware abstraction layer, providing uniform detection and management of GPUs, accelerators, and compute capabilities across platforms.

## Problem Statement

ML deployments face hardware fragmentation:
- CUDA version mismatches (11.x vs 12.x)
- Apple Silicon (MPS) vs NVIDIA vs AMD
- Missing GPU drivers in containers
- Multi-GPU NUMA considerations
- CPU feature detection (AVX, etc.)

Without abstraction, every app must handle these variations.

## Design Goals

1. **Uniform API**: Same code works on CUDA, MPS, and CPU
2. **Auto-detection**: Discover available hardware at startup
3. **Graceful fallback**: Degrade to CPU when GPU unavailable
4. **Lock file integration**: Record hardware identity for reproducibility

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   HARDWARE ABSTRACTION LAYER                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Snakepit.Hardware (public API)                                 │
│  ├── detect/0        - Detect all available hardware            │
│  ├── info/0          - Get current hardware info                │
│  ├── select/1        - Select device for operations             │
│  └── capabilities/0  - Query feature support                    │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Snakepit.Hardware.Detector (internal)                          │
│  ├── CUDA detector   - NVIDIA GPUs via nvidia-smi               │
│  ├── MPS detector    - Apple Silicon via Metal API              │
│  ├── ROCm detector   - AMD GPUs via rocm-smi                    │
│  └── CPU detector    - CPU features via /proc/cpuinfo           │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Snakepit.Hardware.Selector (internal)                          │
│  ├── Automatic selection based on availability + preference     │
│  ├── Affinity hints for worker pool                             │
│  └── Fallback chain: CUDA → MPS → ROCm → CPU                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Hardware Info Types

```elixir
defmodule Snakepit.Hardware do
  @moduledoc """
  Hardware detection and abstraction layer.
  """

  @type accelerator :: :cuda | :mps | :rocm | :cpu

  @type gpu_info :: %{
    id: non_neg_integer(),
    name: String.t(),
    memory_total_mb: non_neg_integer(),
    memory_free_mb: non_neg_integer(),
    compute_capability: String.t() | nil,
    driver_version: String.t() | nil,
    temperature_c: non_neg_integer() | nil,
    utilization_percent: non_neg_integer() | nil
  }

  @type cuda_info :: %{
    version: String.t(),
    driver_version: String.t(),
    cudnn_version: String.t() | nil,
    devices: [gpu_info()]
  }

  @type mps_info :: %{
    available: boolean(),
    device_name: String.t(),
    memory_total_mb: non_neg_integer()
  }

  @type cpu_info :: %{
    cores: non_neg_integer(),
    threads: non_neg_integer(),
    model: String.t(),
    features: [atom()],
    memory_total_mb: non_neg_integer()
  }

  @type hardware_info :: %{
    accelerator: accelerator(),
    cuda: cuda_info() | nil,
    mps: mps_info() | nil,
    rocm: map() | nil,
    cpu: cpu_info(),
    platform: String.t()
  }

  @type capabilities :: %{
    cuda: boolean(),
    cuda_version: String.t() | nil,
    cudnn: boolean(),
    cudnn_version: String.t() | nil,
    mps: boolean(),
    rocm: boolean(),
    avx: boolean(),
    avx2: boolean(),
    avx512: boolean()
  }
end
```

## Detection Implementation

### Main Detector

```elixir
defmodule Snakepit.Hardware.Detector do
  @moduledoc """
  Detects available hardware and capabilities.
  """

  alias Snakepit.Hardware.{CUDADetector, MPSDetector, ROCmDetector, CPUDetector}

  @spec detect() :: Snakepit.Hardware.hardware_info()
  def detect do
    cuda = CUDADetector.detect()
    mps = MPSDetector.detect()
    rocm = ROCmDetector.detect()
    cpu = CPUDetector.detect()

    accelerator = select_accelerator(cuda, mps, rocm)

    %{
      accelerator: accelerator,
      cuda: cuda,
      mps: mps,
      rocm: rocm,
      cpu: cpu,
      platform: detect_platform()
    }
  end

  @spec capabilities() :: Snakepit.Hardware.capabilities()
  def capabilities do
    info = detect()

    %{
      cuda: info.cuda != nil,
      cuda_version: get_in(info, [:cuda, :version]),
      cudnn: get_in(info, [:cuda, :cudnn_version]) != nil,
      cudnn_version: get_in(info, [:cuda, :cudnn_version]),
      mps: info.mps != nil and info.mps.available,
      rocm: info.rocm != nil,
      avx: :avx in info.cpu.features,
      avx2: :avx2 in info.cpu.features,
      avx512: :avx512 in info.cpu.features
    }
  end

  defp select_accelerator(cuda, mps, _rocm) do
    cond do
      cuda != nil and cuda.devices != [] -> :cuda
      mps != nil and mps.available -> :mps
      # rocm != nil -> :rocm  # Future
      true -> :cpu
    end
  end

  defp detect_platform do
    case :os.type() do
      {:unix, :darwin} -> "macos-" <> arch()
      {:unix, :linux} -> "linux-" <> arch()
      {:win32, _} -> "windows-" <> arch()
      _ -> "unknown"
    end
  end

  defp arch do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "x86_64" <> _ -> "x86_64"
      "aarch64" <> _ -> "arm64"
      "arm" <> _ -> "arm64"
      arch -> arch
    end
  end
end
```

### CUDA Detector

```elixir
defmodule Snakepit.Hardware.CUDADetector do
  @moduledoc """
  Detects NVIDIA CUDA GPUs.
  """

  @spec detect() :: Snakepit.Hardware.cuda_info() | nil
  def detect do
    with {:ok, devices} <- detect_devices(),
         {:ok, version} <- detect_cuda_version(),
         {:ok, driver} <- detect_driver_version() do
      %{
        version: version,
        driver_version: driver,
        cudnn_version: detect_cudnn_version(),
        devices: devices
      }
    else
      _ -> nil
    end
  end

  defp detect_devices do
    # Use nvidia-smi for device enumeration
    query = [
      "index",
      "name",
      "memory.total",
      "memory.free",
      "compute_cap",
      "driver_version",
      "temperature.gpu",
      "utilization.gpu"
    ] |> Enum.join(",")

    case System.cmd("nvidia-smi", [
      "--query-gpu=#{query}",
      "--format=csv,noheader,nounits"
    ], stderr_to_stdout: true) do
      {output, 0} ->
        devices = output
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&parse_nvidia_smi_line/1)
        |> Enum.reject(&is_nil/1)

        {:ok, devices}

      _ ->
        {:error, :nvidia_smi_not_found}
    end
  end

  defp parse_nvidia_smi_line(line) do
    case String.split(line, ", ") do
      [id, name, mem_total, mem_free, cc, _driver, temp, util] ->
        %{
          id: String.to_integer(id),
          name: name,
          memory_total_mb: parse_int(mem_total),
          memory_free_mb: parse_int(mem_free),
          compute_capability: cc,
          driver_version: nil,
          temperature_c: parse_int(temp),
          utilization_percent: parse_int(util)
        }
      _ ->
        nil
    end
  end

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp detect_cuda_version do
    case System.cmd("nvcc", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/release (\d+\.\d+)/, output) do
          [_, version] -> {:ok, version}
          _ -> {:error, :parse_failed}
        end
      _ ->
        # Fallback: check nvidia-smi
        case System.cmd("nvidia-smi", [], stderr_to_stdout: true) do
          {output, 0} ->
            case Regex.run(~r/CUDA Version: (\d+\.\d+)/, output) do
              [_, version] -> {:ok, version}
              _ -> {:error, :parse_failed}
            end
          _ ->
            {:error, :cuda_not_found}
        end
    end
  end

  defp detect_driver_version do
    case System.cmd("nvidia-smi", ["--query-gpu=driver_version", "--format=csv,noheader"],
                    stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, :not_found}
    end
  end

  defp detect_cudnn_version do
    # Try to find cuDNN version via Python
    script = """
    import torch
    print(torch.backends.cudnn.version() if torch.backends.cudnn.is_available() else "")
    """

    case run_python(script) do
      {:ok, ""} -> nil
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp run_python(script) do
    case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, :failed}
    end
  end
end
```

### MPS Detector (Apple Silicon)

```elixir
defmodule Snakepit.Hardware.MPSDetector do
  @moduledoc """
  Detects Apple Silicon MPS availability.
  """

  @spec detect() :: Snakepit.Hardware.mps_info() | nil
  def detect do
    # Only available on macOS with Apple Silicon
    case :os.type() do
      {:unix, :darwin} -> detect_mps()
      _ -> nil
    end
  end

  defp detect_mps do
    # Use system_profiler for hardware info
    case System.cmd("system_profiler", ["SPHardwareDataType"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "Apple") do
          %{
            available: check_mps_availability(),
            device_name: extract_chip_name(output),
            memory_total_mb: extract_memory(output)
          }
        else
          nil
        end
      _ ->
        nil
    end
  end

  defp check_mps_availability do
    # Check via PyTorch
    script = """
    import torch
    print(torch.backends.mps.is_available())
    """

    case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == "True"
      _ -> false
    end
  end

  defp extract_chip_name(output) do
    case Regex.run(~r/Chip:\s*(.+)$/m, output) do
      [_, name] -> String.trim(name)
      _ -> "Apple Silicon"
    end
  end

  defp extract_memory(output) do
    case Regex.run(~r/Memory:\s*(\d+)\s*GB/m, output) do
      [_, gb] -> String.to_integer(gb) * 1024
      _ -> 0
    end
  end
end
```

### CPU Detector

```elixir
defmodule Snakepit.Hardware.CPUDetector do
  @moduledoc """
  Detects CPU capabilities.
  """

  @spec detect() :: Snakepit.Hardware.cpu_info()
  def detect do
    %{
      cores: detect_cores(),
      threads: detect_threads(),
      model: detect_model(),
      features: detect_features(),
      memory_total_mb: detect_memory()
    }
  end

  defp detect_cores do
    System.schedulers_online()
  end

  defp detect_threads do
    :erlang.system_info(:logical_processors)
  end

  defp detect_model do
    case :os.type() do
      {:unix, :linux} -> read_cpuinfo_model()
      {:unix, :darwin} -> read_sysctl_model()
      _ -> "Unknown"
    end
  end

  defp detect_features do
    case :os.type() do
      {:unix, :linux} -> read_cpuinfo_features()
      {:unix, :darwin} -> read_sysctl_features()
      _ -> []
    end
  end

  defp detect_memory do
    case :os.type() do
      {:unix, :linux} -> read_meminfo()
      {:unix, :darwin} -> read_sysctl_memory()
      _ -> 0
    end
  end

  defp read_cpuinfo_model do
    case File.read("/proc/cpuinfo") do
      {:ok, content} ->
        case Regex.run(~r/model name\s*:\s*(.+)$/m, content) do
          [_, model] -> String.trim(model)
          _ -> "Unknown"
        end
      _ -> "Unknown"
    end
  end

  defp read_cpuinfo_features do
    case File.read("/proc/cpuinfo") do
      {:ok, content} ->
        case Regex.run(~r/flags\s*:\s*(.+)$/m, content) do
          [_, flags] ->
            flags
            |> String.split()
            |> Enum.filter(&feature_relevant?/1)
            |> Enum.map(&String.to_atom/1)
          _ -> []
        end
      _ -> []
    end
  end

  defp feature_relevant?(flag) do
    flag in ~w(avx avx2 avx512f avx512vl sse sse2 sse4_1 sse4_2 fma)
  end

  defp read_meminfo do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemTotal:\s*(\d+)\s*kB/, content) do
          [_, kb] -> div(String.to_integer(kb), 1024)
          _ -> 0
        end
      _ -> 0
    end
  end

  defp read_sysctl_model do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "Unknown"
    end
  end

  defp read_sysctl_features do
    case System.cmd("sysctl", ["-n", "machdep.cpu.features"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.downcase()
        |> String.split()
        |> Enum.filter(&feature_relevant?/1)
        |> Enum.map(&String.to_atom/1)
      _ -> []
    end
  end

  defp read_sysctl_memory do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {output, 0} ->
        bytes = String.trim(output) |> String.to_integer()
        div(bytes, 1024 * 1024)
      _ -> 0
    end
  end
end
```

## Device Selection

```elixir
defmodule Snakepit.Hardware.Selector do
  @moduledoc """
  Selects appropriate device for execution.
  """

  alias Snakepit.Hardware.Detector

  @type preference :: :auto | :cuda | :mps | :cpu | {:cuda, non_neg_integer()}

  @spec select(preference()) :: {:ok, term()} | {:error, :device_not_available}
  def select(:auto) do
    info = Detector.detect()
    {:ok, info.accelerator}
  end

  def select(:cuda) do
    info = Detector.detect()
    if info.cuda && info.cuda.devices != [] do
      {:ok, {:cuda, 0}}
    else
      {:error, :device_not_available}
    end
  end

  def select({:cuda, id}) do
    info = Detector.detect()
    if info.cuda && Enum.any?(info.cuda.devices, &(&1.id == id)) do
      {:ok, {:cuda, id}}
    else
      {:error, :device_not_available}
    end
  end

  def select(:mps) do
    info = Detector.detect()
    if info.mps && info.mps.available do
      {:ok, :mps}
    else
      {:error, :device_not_available}
    end
  end

  def select(:cpu), do: {:ok, :cpu}

  @doc """
  Selects device with fallback chain.
  """
  @spec select_with_fallback([preference()]) :: {:ok, term()} | {:error, :no_device}
  def select_with_fallback(preferences) do
    Enum.find_value(preferences, {:error, :no_device}, fn pref ->
      case select(pref) do
        {:ok, device} -> {:ok, device}
        _ -> nil
      end
    end)
  end
end
```

## Public API

```elixir
defmodule Snakepit.Hardware do
  @moduledoc """
  Hardware detection and abstraction layer.

  ## Examples

      iex> Snakepit.Hardware.info()
      %{
        accelerator: :cuda,
        cuda: %{version: "12.1", devices: [...]},
        cpu: %{cores: 16, ...}
      }

      iex> Snakepit.Hardware.capabilities()
      %{cuda: true, cuda_version: "12.1", cudnn: true, ...}

      iex> Snakepit.Hardware.select(:cuda)
      {:ok, {:cuda, 0}}
  """

  alias Snakepit.Hardware.{Detector, Selector}

  @doc """
  Detects all available hardware.
  Results are cached for the lifetime of the application.
  """
  @spec detect() :: hardware_info()
  def detect do
    case :persistent_term.get({__MODULE__, :info}, nil) do
      nil ->
        info = Detector.detect()
        :persistent_term.put({__MODULE__, :info}, info)
        info
      info ->
        info
    end
  end

  @doc """
  Returns cached hardware info.
  """
  @spec info() :: hardware_info()
  def info, do: detect()

  @doc """
  Returns hardware capabilities.
  """
  @spec capabilities() :: capabilities()
  def capabilities do
    case :persistent_term.get({__MODULE__, :capabilities}, nil) do
      nil ->
        caps = Detector.capabilities()
        :persistent_term.put({__MODULE__, :capabilities}, caps)
        caps
      caps ->
        caps
    end
  end

  @doc """
  Selects a device for execution.
  """
  @spec select(Selector.preference()) :: {:ok, term()} | {:error, :device_not_available}
  defdelegate select(preference), to: Selector

  @doc """
  Selects device with fallback chain.
  """
  @spec select_with_fallback([Selector.preference()]) :: {:ok, term()} | {:error, :no_device}
  defdelegate select_with_fallback(preferences), to: Selector

  @doc """
  Clears cached hardware info.
  Call after hardware changes (e.g., container migration).
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase({__MODULE__, :info})
    :persistent_term.erase({__MODULE__, :capabilities})
    :ok
  end

  @doc """
  Returns hardware identity for lock file.
  """
  @spec identity() :: map()
  def identity do
    info = detect()
    caps = capabilities()

    %{
      "platform" => info.platform,
      "accelerator" => Atom.to_string(info.accelerator),
      "cuda_version" => caps.cuda_version,
      "cudnn_version" => caps.cudnn_version,
      "gpu_count" => gpu_count(info),
      "cpu_features" => Enum.map(info.cpu.features, &Atom.to_string/1)
    }
  end

  defp gpu_count(%{cuda: %{devices: devices}}) when is_list(devices), do: length(devices)
  defp gpu_count(%{mps: %{available: true}}), do: 1
  defp gpu_count(_), do: 0
end
```

## Configuration

```elixir
config :snakepit, :hardware,
  # Device preference order
  prefer: [:cuda, :mps, :cpu],

  # Specific GPU selection
  cuda_visible_devices: nil,  # nil = all, or "0,1"

  # Memory thresholds
  min_gpu_memory_mb: 2048,

  # Auto-detection
  detect_on_startup: true,
  cache_detection: true
```

## Telemetry Events

```elixir
# Hardware detected
[:snakepit, :hardware, :detected]
# Measurements: %{gpu_count: 2, memory_total_mb: 80000}
# Metadata: %{accelerator: :cuda, platform: "linux-x86_64"}

# Device selected
[:snakepit, :hardware, :device_selected]
# Measurements: %{}
# Metadata: %{device: {:cuda, 0}, reason: :auto}

# Device unavailable
[:snakepit, :hardware, :device_unavailable]
# Measurements: %{}
# Metadata: %{requested: :cuda, fallback: :cpu}
```

## Integration with Worker Pool

```elixir
defmodule Snakepit.WorkerPool do
  # Workers can be assigned device affinity

  def checkout(opts \\ []) do
    device = Keyword.get(opts, :device, :auto)

    case Snakepit.Hardware.select(device) do
      {:ok, selected_device} ->
        get_worker_for_device(selected_device)

      {:error, :device_not_available} ->
        # Fallback to CPU
        get_worker_for_device(:cpu)
    end
  end
end
```

## Lock File Integration

The hardware identity is included in `snakebridge.lock`:

```json
{
  "environment": {
    "hardware": {
      "platform": "linux-x86_64",
      "accelerator": "cuda",
      "cuda_version": "12.1",
      "cudnn_version": "8.9.0",
      "gpu_count": 2,
      "cpu_features": ["avx", "avx2", "avx512f"]
    }
  }
}
```

## Implementation Phases

### Phase 1: Core Detection (Week 1)
- [ ] CUDA detector via nvidia-smi
- [ ] CPU detector via /proc/cpuinfo
- [ ] Platform detection

### Phase 2: Apple Silicon (Week 1-2)
- [ ] MPS detector
- [ ] Cross-platform abstraction

### Phase 3: Selection & Caching (Week 2)
- [ ] Device selector
- [ ] Fallback chains
- [ ] Persistent term caching

### Phase 4: Integration (Week 3)
- [ ] Worker pool affinity
- [ ] Lock file identity
- [ ] Telemetry events

## SnakeBridge Integration

SnakeBridge uses hardware info for:

1. **Lock file**: Include hardware identity for reproducibility
2. **Wheel selection**: Choose correct PyTorch wheel (cu121, cpu, etc.)
3. **Generated code**: Add device hints to generated wrappers
4. **Documentation**: Show available devices in generated docs

See: `snakebridge/docs/20251227/world-class-ml/01-hardware-aware-lockfile.md`
