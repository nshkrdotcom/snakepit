# Hardware Detection for ML Workloads

Snakepit provides a unified hardware abstraction layer for machine learning workloads. The hardware detection system automatically identifies available accelerators at startup and provides a consistent API for device selection.

## Overview

| Accelerator | Description | Detection Method |
|-------------|-------------|------------------|
| **CPU** | Always available fallback | Erlang system info |
| **CUDA** | NVIDIA GPUs | `nvidia-smi` queries |
| **MPS** | Apple Metal Performance Shaders | macOS sysctl |
| **ROCm** | AMD GPUs | `rocm-smi` queries |

Priority order: CUDA > MPS > ROCm > CPU.

## Hardware.detect/0

Returns comprehensive hardware information as a map. Results are cached.

```elixir
info = Snakepit.Hardware.detect()
# => %{
#   accelerator: :cuda,
#   platform: "linux-x86_64",
#   cpu: %{cores: 8, threads: 16, model: "Intel Core i7-9700K", features: [:avx, :avx2], memory_total_mb: 32768},
#   cuda: %{version: "12.1", driver_version: "535.104.05", cudnn_version: "8.9.0",
#           devices: [%{id: 0, name: "RTX 3080", memory_total_mb: 10240, compute_capability: "8.6"}]},
#   mps: nil,
#   rocm: nil
# }
```

## Hardware.capabilities/0

Returns boolean capability flags for quick feature checks.

```elixir
caps = Snakepit.Hardware.capabilities()
# => %{cuda: true, mps: false, rocm: false, avx: true, avx2: true, avx512: false,
#      cuda_version: "12.1", cudnn_version: "8.9", cudnn: true}

if caps.cuda and caps.cudnn do
  IO.puts("Full CUDA acceleration available")
end
```

## Hardware.select/1

Selects a device based on preference. Returns `{:ok, device}` or `{:error, :device_not_available}`.

```elixir
{:ok, device} = Snakepit.Hardware.select(:auto)   # Best available
{:ok, {:cuda, 0}} = Snakepit.Hardware.select(:cuda)
{:ok, :mps} = Snakepit.Hardware.select(:mps)
{:ok, :cpu} = Snakepit.Hardware.select(:cpu)
{:ok, {:cuda, 1}} = Snakepit.Hardware.select({:cuda, 1})  # Specific GPU
```

| Option | Description |
|--------|-------------|
| `:auto` | Automatically select best available |
| `:cpu` | Select CPU (always succeeds) |
| `:cuda` | Select CUDA device 0 |
| `:mps` | Select Apple MPS |
| `:rocm` | Select ROCm device 0 |
| `{:cuda, id}` | Select specific CUDA device |
| `{:rocm, id}` | Select specific ROCm device |

## Hardware.select_with_fallback/1

Tries devices in order until one is available. Useful for graceful degradation.

```elixir
{:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])
# On CUDA: {:ok, {:cuda, 0}}
# On Mac: {:ok, :mps}
# Otherwise: {:ok, :cpu}
```

## Hardware.identity/0

Returns a hardware identity map for lock files and reproducible environments.

```elixir
identity = Snakepit.Hardware.identity()
# => %{"platform" => "linux-x86_64", "accelerator" => "cuda",
#      "cpu_features" => ["avx", "avx2"], "gpu_count" => 2}

File.write!("hardware.lock", Jason.encode!(identity))
```

## Accelerator Details

### CPU Features
- **AVX/AVX2**: Vector operations for numerical computing
- **AVX-512**: Advanced vector extensions for HPC
- **SSE4.1/SSE4.2**: Streaming SIMD extensions
- **FMA**: Fused multiply-add operations

### CUDA (NVIDIA)
Detection provides: driver/runtime versions, cuDNN version, per-device name, memory, and compute capability.

### MPS (Apple Silicon)
Detection provides: availability, device name, unified memory total.

### ROCm (AMD)
Detection provides: ROCm version, per-device name and memory.

## Complete ML Workload Example

```elixir
defmodule MyApp.MLWorker do
  alias Snakepit.Hardware

  def select_device do
    caps = Hardware.capabilities()
    cond do
      caps.cuda and caps.cudnn -> Hardware.select(:cuda)
      caps.mps -> Hardware.select(:mps)
      true -> {:ok, :cpu}
    end
  end

  def run_inference(model, input) do
    {:ok, device} = select_device()
    Snakepit.execute("inference", %{model: model, input: input, device: format_device(device)})
  end

  defp format_device(:cpu), do: "cpu"
  defp format_device(:mps), do: "mps"
  defp format_device({:cuda, id}), do: "cuda:#{id}"
  defp format_device({:rocm, id}), do: "rocm:#{id}"
end
```

## Cache Management

```elixir
Snakepit.Hardware.clear_cache()  # Force re-detection
```
