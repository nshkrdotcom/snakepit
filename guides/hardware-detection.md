# Hardware Detection

Snakepit provides automatic hardware detection for ML workloads,
supporting CPU, NVIDIA CUDA, Apple MPS, and AMD ROCm accelerators.

## Quick Start

```elixir
# Detect all hardware
info = Snakepit.Hardware.detect()
# => %{accelerator: :cuda, cpu: %{...}, cuda: %{...}, ...}

# Check capabilities
caps = Snakepit.Hardware.capabilities()
# => %{cuda: true, mps: false, avx2: true, ...}

# Select device
{:ok, device} = Snakepit.Hardware.select(:auto)
# => {:ok, {:cuda, 0}}
```

## Hardware Info Structure

The `detect/0` function returns a comprehensive map:

```elixir
%{
  accelerator: :cuda,           # Primary accelerator
  platform: "linux-x86_64",     # Platform string
  cpu: %{
    cores: 8,
    threads: 16,
    model: "Intel Core i7-...",
    features: [:avx, :avx2, :sse4_2],
    memory_total_mb: 32768
  },
  cuda: %{
    version: "12.1",
    driver_version: "535.104.05",
    devices: [
      %{
        id: 0,
        name: "NVIDIA GeForce RTX 3080",
        memory_total_mb: 10240,
        memory_free_mb: 9500,
        compute_capability: "8.6"
      }
    ],
    cudnn_version: nil
  },
  mps: nil,
  rocm: nil
}
```

## Device Selection

### Automatic Selection

```elixir
# Select best available device
{:ok, device} = Snakepit.Hardware.select(:auto)
```

### Specific Device

```elixir
# Request CUDA (fails if unavailable)
case Snakepit.Hardware.select(:cuda) do
  {:ok, {:cuda, 0}} -> IO.puts("Using CUDA device 0")
  {:error, :device_not_available} -> IO.puts("CUDA not available")
end

# Request specific CUDA device
{:ok, {:cuda, 1}} = Snakepit.Hardware.select({:cuda, 1})
```

### Fallback Strategy

```elixir
# Prefer CUDA, fall back to MPS, then CPU
{:ok, device} = Snakepit.Hardware.select_with_fallback([:cuda, :mps, :cpu])
```

## Capability Flags

```elixir
caps = Snakepit.Hardware.capabilities()

if caps.cuda do
  IO.puts("CUDA version: #{caps.cuda_version}")
end

if caps.avx2 do
  IO.puts("AVX2 available for optimized CPU operations")
end
```

## Lock File Identity

For reproducible environments, generate a hardware identity map:

```elixir
identity = Snakepit.Hardware.identity()
# => %{
#   "platform" => "linux-x86_64",
#   "accelerator" => "cuda",
#   "cpu_features" => ["avx", "avx2"],
#   "gpu_count" => 1
# }

# Save to lock file
File.write!("hardware.lock", Jason.encode!(identity))
```

## Caching

Hardware detection results are cached for performance:

```elixir
# Clear cache to force re-detection
Snakepit.Hardware.clear_cache()
```
