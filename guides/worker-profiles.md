# Worker Profiles Guide

Snakepit supports two worker profiles that define how Python processes are created and managed. This guide explains each profile, when to use it, and how to configure it.

---

## Table of Contents

1. [Overview](#overview)
2. [Process Profile](#process-profile)
3. [Thread Profile](#thread-profile)
4. [Decision Matrix](#decision-matrix)
5. [Configuration Examples](#configuration-examples)
6. [Thread Safety Requirements](#thread-safety-requirements)
7. [Migration Considerations](#migration-considerations)

---

## Overview

Worker profiles determine the concurrency model for your Python workers:

| Profile | Python Processes | Concurrency Model | Total Capacity |
|---------|------------------|-------------------|----------------|
| `:process` | Many (e.g., 100) | One request per process | `pool_size` |
| `:thread` | Few (e.g., 4) | Many threads per process | `pool_size * threads_per_worker` |

Choose based on your workload characteristics, Python version, and performance requirements.

---

## Process Profile

**Module:** `Snakepit.WorkerProfile.Process`

The process profile is the default and most compatible mode. Each worker runs as a separate OS process with a single-threaded Python interpreter.

### How It Works

```
Pool (100 workers)
  |
  +-- Worker 1 [PID 12345] -- 1 gRPC connection -- Handles 1 request at a time
  +-- Worker 2 [PID 12346] -- 1 gRPC connection -- Handles 1 request at a time
  +-- Worker 3 [PID 12347] -- 1 gRPC connection -- Handles 1 request at a time
  ...
  +-- Worker 100 [PID 12444] -- 1 gRPC connection -- Handles 1 request at a time
```

### Isolation

- **Full process isolation**: Each worker is an independent OS process with its own memory space
- **Crash containment**: A crash in one worker cannot affect others
- **GIL irrelevant**: Each process has its own Global Interpreter Lock

### Use Cases

The process profile is ideal for:

- **I/O-bound workloads**: Web scraping, API calls, file operations, database queries
- **High concurrency**: Applications needing 100+ simultaneous workers
- **Legacy Python code**: Works with all Python versions (3.8+)
- **Untrusted code**: Process isolation provides security boundaries
- **Memory-sensitive workloads**: Each worker's memory can be recycled independently

### Configuration

```elixir
config :snakepit,
  pools: [
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 100,
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "1"},
        {"OMP_NUM_THREADS", "1"}
      ],
      startup_batch_size: 10,
      startup_batch_delay_ms: 500
    }
  ]
```

### Environment Variables

The process profile automatically enforces single-threading in scientific libraries to prevent resource contention:

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENBLAS_NUM_THREADS` | `"1"` | OpenBLAS thread control |
| `MKL_NUM_THREADS` | `"1"` | Intel MKL thread control |
| `OMP_NUM_THREADS` | `"1"` | OpenMP thread control |
| `NUMEXPR_NUM_THREADS` | `"1"` | NumExpr thread control |
| `VECLIB_MAXIMUM_THREADS` | `"1"` | macOS Accelerate framework |

---

## Thread Profile

**Module:** `Snakepit.WorkerProfile.Thread`

The thread profile runs fewer Python processes, each with an internal thread pool. Optimized for Python 3.13+ with free-threading support.

### How It Works

```
Pool (4 workers)
  |
  +-- Worker 1 [PID 12345]
  |     +-- Thread Pool (16 threads)
  |     +-- Handles 16 concurrent requests
  |
  +-- Worker 2 [PID 12346]
  |     +-- Thread Pool (16 threads)
  |     +-- Handles 16 concurrent requests
  ...

Total capacity: 4 workers * 16 threads = 64 concurrent requests
```

### Isolation

- **Thread-level isolation**: Multiple requests execute concurrently in the same Python interpreter
- **Shared memory**: Threads within a process can share data without serialization
- **GIL handling**: Requires Python 3.13+ for optimal free-threading performance

### Use Cases

The thread profile is ideal for:

- **CPU-bound workloads**: Machine learning inference, numerical computation
- **Large shared data**: Zero-copy data sharing within a worker process
- **Memory efficiency**: Fewer interpreter instances reduce memory footprint
- **High throughput**: HTTP/2 multiplexing enables concurrent requests to the same worker

### Requirements

- **Python 3.13+**: For optimal free-threading performance
- **Thread-safe adapters**: Your Python code must be thread-safe
- **Thread-safe libraries**: NumPy, PyTorch, TensorFlow are supported

### Configuration

```elixir
config :snakepit,
  pools: [
    %{
      name: :ml_inference,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 16,  # 64 total capacity
      adapter_module: Snakepit.Adapters.GRPCPython,
      adapter_args: ["--adapter", "myapp.ml.InferenceAdapter"],
      adapter_env: [
        {"OPENBLAS_NUM_THREADS", "16"},
        {"OMP_NUM_THREADS", "16"},
        {"CUDA_VISIBLE_DEVICES", "0"}
      ],
      thread_safety_checks: true,
      worker_ttl: {1800, :seconds},
      worker_max_requests: 10000
    }
  ]
```

### Capacity Tracking

The thread profile tracks in-flight requests per worker using the CapacityStore module:

- Load-aware worker selection routes requests to least-busy workers
- Capacity limits prevent thread pool exhaustion
- Telemetry provides visibility into load distribution

---

## Decision Matrix

Use this matrix to choose the right profile:

| Consideration | Process Profile | Thread Profile |
|---------------|-----------------|----------------|
| **Python Version** | 3.8+ | 3.13+ recommended |
| **Workload Type** | I/O-bound | CPU-bound |
| **Concurrency** | High (100+ workers) | Moderate (4-16 workers) |
| **Memory Usage** | Higher (many interpreters) | Lower (few interpreters) |
| **Isolation** | Full process isolation | Thread isolation only |
| **Crash Impact** | Single worker | Single worker (all threads) |
| **Data Sharing** | Via serialization | In-process (zero-copy) |
| **Configuration** | Simple | Requires thread-safe code |
| **Startup Time** | Longer (many processes) | Shorter (few processes) |

### When to Use Process Profile

Choose process profile if:

- You are running Python < 3.13
- Your Python code is not verified thread-safe
- You need maximum isolation between requests
- Your workload is primarily I/O-bound
- You are running untrusted or third-party code

### When to Use Thread Profile

Choose thread profile if:

- You are running Python 3.13+ with free-threading
- Your adapter code is verified thread-safe
- You have CPU-bound ML inference workloads
- Memory efficiency is critical
- You need to share large models across requests

---

## Configuration Examples

### Process Profile: Web Scraping Pool

```elixir
%{
  name: :scrapers,
  worker_profile: :process,
  pool_size: 50,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "myapp.scrapers.WebAdapter"],
  adapter_env: [
    {"OPENBLAS_NUM_THREADS", "1"},
    {"OMP_NUM_THREADS", "1"}
  ],
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 5000,
    timeout_ms: 15000
  }
}
```

### Thread Profile: ML Inference Pool

```elixir
%{
  name: :ml_inference,
  worker_profile: :thread,
  pool_size: 4,
  threads_per_worker: 8,
  adapter_module: Snakepit.Adapters.GRPCPython,
  adapter_args: ["--adapter", "myapp.ml.InferenceAdapter"],
  adapter_env: [
    {"OPENBLAS_NUM_THREADS", "8"},
    {"OMP_NUM_THREADS", "8"},
    {"CUDA_VISIBLE_DEVICES", "0"}
  ],
  thread_safety_checks: true,
  worker_ttl: {1800, :seconds},
  heartbeat: %{
    enabled: true,
    ping_interval_ms: 10000,
    timeout_ms: 60000,
    max_missed_heartbeats: 2
  }
}
```

### Hybrid Setup: Both Profiles

```elixir
config :snakepit,
  pools: [
    # I/O-bound tasks
    %{
      name: :default,
      worker_profile: :process,
      pool_size: 50,
      adapter_module: Snakepit.Adapters.GRPCPython
    },
    # CPU-bound inference
    %{
      name: :ml,
      worker_profile: :thread,
      pool_size: 4,
      threads_per_worker: 16,
      adapter_args: ["--adapter", "myapp.ml.ModelAdapter"]
    }
  ]
```

---

## Thread Safety Requirements

When using the thread profile, your Python adapter must be thread-safe.

### Thread-Safe Adapter Pattern

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method, tool

class MyAdapter(ThreadSafeAdapter):
    __thread_safe__ = True  # Required declaration

    def __init__(self):
        super().__init__()
        # Pattern 1: Shared read-only (loaded once)
        self.model = self._load_model()

        # Pattern 3: Shared mutable (requires locking)
        self.request_count = 0

    def _load_model(self):
        import torch
        model = torch.load("model.pt")
        model.eval()
        return model

    @thread_safe_method
    @tool(description="Run inference")
    def predict(self, input_data: list) -> dict:
        # Pattern 2: Thread-local cache
        cache = self.get_thread_local('cache', {})

        # Read shared model (no lock needed)
        with torch.no_grad():
            result = self.model(torch.tensor(input_data))

        # Update shared state (lock required)
        with self.acquire_lock():
            self.request_count += 1

        return {"prediction": result.tolist()}
```

### Three Safety Patterns

1. **Shared Read-Only**: Load data once in `__init__`, never modify
2. **Thread-Local Storage**: Use `get_thread_local()` for per-thread caches
3. **Locked Writes**: Use `with self.acquire_lock()` for shared mutable state

### Thread-Safe Libraries

| Library | Thread-Safe | Notes |
|---------|-------------|-------|
| NumPy | Yes | Releases GIL during computation |
| PyTorch | Yes | Configure with `torch.set_num_threads()` |
| TensorFlow | Yes | Use `tf.config.threading` |
| Scikit-learn | Yes | Set `n_jobs=1` per estimator |
| Pandas | No | Use Polars or lock all operations |

See [Python Threading Guide](../priv/python/README_THREADING.md) for comprehensive guidance.

---

## Migration Considerations

### From Process to Thread Profile

1. **Verify Python version**: Requires Python 3.13+ for best results
2. **Audit adapter code**: Ensure all methods are thread-safe
3. **Update adapter base class**: Change `BaseAdapter` to `ThreadSafeAdapter`
4. **Add thread safety markers**: Decorate methods with `@thread_safe_method`
5. **Test under load**: Use concurrent tests to verify correctness

### Configuration Changes

```elixir
# Before (process profile)
%{
  name: :ml,
  pool_size: 32,
  adapter_module: Snakepit.Adapters.GRPCPython
}

# After (thread profile)
%{
  name: :ml,
  worker_profile: :thread,
  pool_size: 4,
  threads_per_worker: 8,  # Same total capacity
  adapter_module: Snakepit.Adapters.GRPCPython,
  thread_safety_checks: true  # Enable during migration
}
```

### Testing Thread Safety

Enable runtime checks during migration:

```elixir
%{
  name: :ml,
  worker_profile: :thread,
  thread_safety_checks: true
}
```

Run concurrent load tests:

```elixir
# Hammer test with concurrent requests
tasks = for _ <- 1..1000 do
  Task.async(fn ->
    Snakepit.execute("predict", %{data: [1, 2, 3]}, pool_name: :ml)
  end)
end

results = Task.await_many(tasks, 60_000)
assert Enum.all?(results, &match?({:ok, _}, &1))
```

---

## Related Guides

- [Getting Started](getting-started.md) - Installation and basics
- [Configuration](configuration.md) - All configuration options
- [Python Adapters](python-adapters.md) - Thread-safe adapter patterns
- [Python Threading Guide](../priv/python/README_THREADING.md) - Python-side threading details
