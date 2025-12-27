# Zero-Copy Tensor Protocol

## Overview

This document specifies Snakepit's zero-copy tensor interchange protocol, enabling sub-microsecond transfers of large tensors between Elixir and Python without memory copying.

## Problem Statement

Current data transfer between Elixir and Python uses JSON serialization:

```elixir
# Current: 10GB tensor → JSON encode → transfer → JSON decode
# Time: ~30 seconds, Memory: 20GB peak (2x for copy)
```

For ML workloads, this is unacceptable. A training batch of 1024 images at 224x224x3 is ~150MB. Serializing this per batch destroys throughput.

## Solution Architecture

### Three-Tier Protocol

```
┌─────────────────────────────────────────────────────────────────┐
│                     ZERO-COPY PROTOCOL                          │
├─────────────────────────────────────────────────────────────────┤
│  Tier 1: Shared Memory (CPU)                                    │
│  ├── mmap-based shared memory regions                           │
│  ├── POSIX shm_open / Windows CreateFileMapping                 │
│  └── Elixir binary ↔ NumPy array sharing                        │
├─────────────────────────────────────────────────────────────────┤
│  Tier 2: Apache Arrow (Columnar/Tabular)                        │
│  ├── Arrow C Data Interface for zero-copy                       │
│  ├── IPC format for cross-process sharing                       │
│  └── Pandas/Polars DataFrame interchange                        │
├─────────────────────────────────────────────────────────────────┤
│  Tier 3: DLPack (GPU Tensors)                                   │
│  ├── CUDA IPC for GPU memory sharing                            │
│  ├── cudaIpcGetMemHandle / cudaIpcOpenMemHandle                 │
│  └── PyTorch/JAX/CuPy tensor interchange                        │
└─────────────────────────────────────────────────────────────────┘
```

## Tier 1: Shared Memory for CPU Arrays

### Design

Use OS-level shared memory to allow Elixir and Python to access the same physical memory.

### Elixir API

```elixir
defmodule Snakepit.ZeroCopy do
  @moduledoc """
  Zero-copy tensor interchange between Elixir and Python.
  """

  @type shape :: [non_neg_integer()]
  @type dtype :: :float32 | :float64 | :int32 | :int64 | :uint8 | :bool
  @type device :: :cpu | {:cuda, non_neg_integer()} | :mps

  @type tensor_ref :: %__MODULE__.TensorRef{
    id: binary(),
    shape: shape(),
    dtype: dtype(),
    device: device(),
    shm_name: binary(),
    byte_size: non_neg_integer(),
    strides: [non_neg_integer()] | nil
  }

  @doc """
  Allocates a zero-copy tensor in shared memory.
  Returns a reference that can be passed to Python.
  """
  @spec allocate(shape(), dtype(), keyword()) :: {:ok, tensor_ref()} | {:error, term()}
  def allocate(shape, dtype, opts \\ []) do
    device = Keyword.get(opts, :device, :cpu)

    case device do
      :cpu -> allocate_cpu(shape, dtype, opts)
      {:cuda, _} -> allocate_cuda(shape, dtype, opts)
      :mps -> {:error, :mps_not_supported}
    end
  end

  @doc """
  Wraps an existing Elixir binary as a zero-copy tensor.
  The binary must remain referenced for the tensor's lifetime.
  """
  @spec from_binary(binary(), shape(), dtype()) :: {:ok, tensor_ref()} | {:error, term()}
  def from_binary(binary, shape, dtype) when is_binary(binary) do
    # Create shared memory segment
    # Copy binary into it (one-time cost)
    # Return reference
  end

  @doc """
  Reads tensor data back into an Elixir binary.
  This copies data - use sparingly for large tensors.
  """
  @spec to_binary(tensor_ref()) :: {:ok, binary()} | {:error, term()}
  def to_binary(%TensorRef{} = ref) do
    # Map shared memory
    # Read bytes
    # Return as binary
  end

  @doc """
  Releases a tensor reference.
  The shared memory is freed when all references (Elixir + Python) are released.
  """
  @spec release(tensor_ref()) :: :ok
  def release(%TensorRef{} = ref) do
    # Decrement reference count
    # Unmap if last reference
  end
end
```

### Python Bridge

```python
# snakepit/zero_copy.py

import numpy as np
from multiprocessing import shared_memory
from dataclasses import dataclass
from typing import Tuple, Optional
import struct

DTYPE_MAP = {
    'float32': np.float32,
    'float64': np.float64,
    'int32': np.int32,
    'int64': np.int64,
    'uint8': np.uint8,
    'bool': np.bool_,
}

@dataclass
class TensorRef:
    id: str
    shape: Tuple[int, ...]
    dtype: str
    shm_name: str
    byte_size: int
    strides: Optional[Tuple[int, ...]] = None

def from_ref(ref: TensorRef) -> np.ndarray:
    """
    Creates a NumPy array that shares memory with Elixir.
    Modifications are visible to both sides immediately.
    """
    shm = shared_memory.SharedMemory(name=ref.shm_name)
    dtype = DTYPE_MAP[ref.dtype]

    # Create array view over shared memory
    arr = np.ndarray(
        shape=ref.shape,
        dtype=dtype,
        buffer=shm.buf,
        strides=ref.strides
    )

    # Attach shm reference to array to prevent cleanup
    arr._shm = shm
    return arr

def to_ref(arr: np.ndarray, name: Optional[str] = None) -> TensorRef:
    """
    Creates shared memory from a NumPy array.
    Returns a TensorRef that can be sent to Elixir.
    """
    import uuid
    shm_name = name or f"snakepit_{uuid.uuid4().hex[:16]}"

    # Create shared memory
    shm = shared_memory.SharedMemory(
        name=shm_name,
        create=True,
        size=arr.nbytes
    )

    # Copy data into shared memory
    shared_arr = np.ndarray(arr.shape, dtype=arr.dtype, buffer=shm.buf)
    shared_arr[:] = arr[:]

    return TensorRef(
        id=shm_name,
        shape=arr.shape,
        dtype=arr.dtype.name,
        shm_name=shm_name,
        byte_size=arr.nbytes,
        strides=arr.strides
    )
```

### NIF Implementation

```c
// c_src/zero_copy_nif.c

#include <erl_nif.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

// Resource type for tracking shared memory
static ErlNifResourceType* SHM_RESOURCE;

typedef struct {
    char* name;
    void* ptr;
    size_t size;
    int fd;
} shm_resource_t;

static void shm_resource_destructor(ErlNifEnv* env, void* obj) {
    shm_resource_t* res = (shm_resource_t*)obj;
    if (res->ptr != MAP_FAILED) {
        munmap(res->ptr, res->size);
    }
    if (res->fd >= 0) {
        close(res->fd);
    }
    if (res->name) {
        shm_unlink(res->name);
        free(res->name);
    }
}

static ERL_NIF_TERM allocate_shm(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    // argv[0] = name (binary)
    // argv[1] = size (integer)

    ErlNifBinary name_bin;
    unsigned long size;

    if (!enif_inspect_binary(env, argv[0], &name_bin) ||
        !enif_get_ulong(env, argv[1], &size)) {
        return enif_make_badarg(env);
    }

    // Create null-terminated name
    char* name = malloc(name_bin.size + 1);
    memcpy(name, name_bin.data, name_bin.size);
    name[name_bin.size] = '\0';

    // Create shared memory
    int fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        free(name);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "shm_open_failed"));
    }

    if (ftruncate(fd, size) < 0) {
        close(fd);
        shm_unlink(name);
        free(name);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "ftruncate_failed"));
    }

    void* ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        close(fd);
        shm_unlink(name);
        free(name);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "mmap_failed"));
    }

    // Create resource
    shm_resource_t* res = enif_alloc_resource(SHM_RESOURCE, sizeof(shm_resource_t));
    res->name = name;
    res->ptr = ptr;
    res->size = size;
    res->fd = fd;

    ERL_NIF_TERM resource_term = enif_make_resource(env, res);
    enif_release_resource(res);

    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        resource_term);
}

static ERL_NIF_TERM write_binary_to_shm(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    // argv[0] = shm resource
    // argv[1] = binary data
    // argv[2] = offset

    shm_resource_t* res;
    ErlNifBinary data;
    unsigned long offset;

    if (!enif_get_resource(env, argv[0], SHM_RESOURCE, (void**)&res) ||
        !enif_inspect_binary(env, argv[1], &data) ||
        !enif_get_ulong(env, argv[2], &offset)) {
        return enif_make_badarg(env);
    }

    if (offset + data.size > res->size) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "buffer_overflow"));
    }

    memcpy((char*)res->ptr + offset, data.data, data.size);

    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM read_binary_from_shm(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    // argv[0] = shm resource
    // argv[1] = offset
    // argv[2] = size

    shm_resource_t* res;
    unsigned long offset, size;

    if (!enif_get_resource(env, argv[0], SHM_RESOURCE, (void**)&res) ||
        !enif_get_ulong(env, argv[1], &offset) ||
        !enif_get_ulong(env, argv[2], &size)) {
        return enif_make_badarg(env);
    }

    if (offset + size > res->size) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "buffer_overflow"));
    }

    ERL_NIF_TERM binary;
    unsigned char* buf = enif_make_new_binary(env, size, &binary);
    memcpy(buf, (char*)res->ptr + offset, size);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), binary);
}

static ErlNifFunc nif_funcs[] = {
    {"allocate_shm", 2, allocate_shm, 0},
    {"write_binary_to_shm", 3, write_binary_to_shm, 0},
    {"read_binary_from_shm", 3, read_binary_from_shm, 0},
};

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    SHM_RESOURCE = enif_open_resource_type(
        env, NULL, "shm_resource",
        shm_resource_destructor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    return 0;
}

ERL_NIF_INIT(Elixir.Snakepit.ZeroCopy.NIF, nif_funcs, load, NULL, NULL, NULL)
```

## Tier 2: Apache Arrow Integration

### Elixir API

```elixir
defmodule Snakepit.Arrow do
  @moduledoc """
  Apache Arrow integration for zero-copy columnar data interchange.
  """

  @type array_ref :: %__MODULE__.ArrayRef{
    schema: map(),
    buffers: [binary()],
    null_count: non_neg_integer(),
    offset: non_neg_integer()
  }

  @type table_ref :: %__MODULE__.TableRef{
    schema: map(),
    columns: [array_ref()],
    num_rows: non_neg_integer()
  }

  @doc """
  Creates an Arrow array from an Elixir list.
  Uses Arrow's memory layout for zero-copy access from Python.
  """
  @spec from_list(list(), atom()) :: {:ok, array_ref()} | {:error, term()}
  def from_list(list, type) when is_list(list) do
    # Allocate Arrow-format buffers
    # Write data in Arrow layout
    # Return reference
  end

  @doc """
  Creates an Arrow table from a map of columns.
  """
  @spec from_columns(map()) :: {:ok, table_ref()} | {:error, term()}
  def from_columns(columns) when is_map(columns) do
    # Build schema from column types
    # Allocate RecordBatch
    # Return reference
  end

  @doc """
  Imports a PyArrow table reference.
  """
  @spec import_table(map()) :: {:ok, table_ref()} | {:error, term()}
  def import_table(arrow_ipc_ref) do
    # Read Arrow IPC format
    # Map buffers into Elixir
    # Return table_ref
  end

  @doc """
  Exports to Arrow IPC format for Python consumption.
  """
  @spec export_ipc(table_ref()) :: {:ok, binary()} | {:error, term()}
  def export_ipc(%TableRef{} = table) do
    # Serialize to Arrow IPC
    # Return bytes
  end
end
```

### Python Integration

```python
# snakepit/arrow_bridge.py

import pyarrow as pa
from typing import Dict, Any

def from_elixir_ipc(ipc_bytes: bytes) -> pa.Table:
    """
    Deserializes Arrow IPC bytes from Elixir into a PyArrow table.
    Zero-copy if buffers are aligned.
    """
    reader = pa.ipc.open_stream(pa.BufferReader(ipc_bytes))
    return reader.read_all()

def to_elixir_ipc(table: pa.Table) -> bytes:
    """
    Serializes a PyArrow table to Arrow IPC format.
    """
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, table.schema)
    writer.write_table(table)
    writer.close()
    return sink.getvalue().to_pybytes()

def pandas_to_elixir(df) -> bytes:
    """
    Converts a Pandas DataFrame to Arrow IPC for Elixir.
    """
    table = pa.Table.from_pandas(df)
    return to_elixir_ipc(table)

def elixir_to_pandas(ipc_bytes: bytes):
    """
    Converts Arrow IPC from Elixir to a Pandas DataFrame.
    """
    table = from_elixir_ipc(ipc_bytes)
    return table.to_pandas()
```

## Tier 3: DLPack for GPU Tensors

### CUDA IPC Protocol

```elixir
defmodule Snakepit.DLPack do
  @moduledoc """
  DLPack integration for GPU tensor interchange.
  Uses CUDA IPC for zero-copy GPU memory sharing.
  """

  @type gpu_tensor_ref :: %__MODULE__.GPUTensorRef{
    ipc_handle: binary(),  # cudaIpcMemHandle_t (64 bytes)
    shape: [non_neg_integer()],
    dtype: atom(),
    device_id: non_neg_integer(),
    byte_size: non_neg_integer(),
    strides: [non_neg_integer()] | nil
  }

  @doc """
  Imports a GPU tensor from Python.
  Returns a reference that can be used in subsequent Python calls.
  """
  @spec import_gpu_tensor(map()) :: {:ok, gpu_tensor_ref()} | {:error, term()}
  def import_gpu_tensor(ref_map) do
    %GPUTensorRef{
      ipc_handle: Base.decode64!(ref_map["ipc_handle"]),
      shape: ref_map["shape"],
      dtype: String.to_atom(ref_map["dtype"]),
      device_id: ref_map["device_id"],
      byte_size: ref_map["byte_size"],
      strides: ref_map["strides"]
    }
  end

  @doc """
  Exports a GPU tensor reference for Python.
  """
  @spec export_gpu_tensor(gpu_tensor_ref()) :: map()
  def export_gpu_tensor(%GPUTensorRef{} = ref) do
    %{
      "ipc_handle" => Base.encode64(ref.ipc_handle),
      "shape" => ref.shape,
      "dtype" => Atom.to_string(ref.dtype),
      "device_id" => ref.device_id,
      "byte_size" => ref.byte_size,
      "strides" => ref.strides
    }
  end
end
```

### Python GPU Bridge

```python
# snakepit/dlpack_bridge.py

import torch
import cupy
from dataclasses import dataclass
from typing import Tuple, Optional
import base64

@dataclass
class GPUTensorRef:
    ipc_handle: bytes
    shape: Tuple[int, ...]
    dtype: str
    device_id: int
    byte_size: int
    strides: Optional[Tuple[int, ...]] = None

def tensor_to_ref(tensor: torch.Tensor) -> GPUTensorRef:
    """
    Creates a GPU tensor reference that can be sent to Elixir.
    Uses CUDA IPC for cross-process sharing.
    """
    if not tensor.is_cuda:
        raise ValueError("Tensor must be on CUDA device")

    # Get CUDA IPC handle
    handle = tensor.storage()._share_cuda_()[1]

    return GPUTensorRef(
        ipc_handle=handle,
        shape=tuple(tensor.shape),
        dtype=str(tensor.dtype).split('.')[-1],
        device_id=tensor.device.index,
        byte_size=tensor.nelement() * tensor.element_size(),
        strides=tuple(tensor.stride())
    )

def ref_to_tensor(ref: GPUTensorRef) -> torch.Tensor:
    """
    Opens a GPU tensor from a reference.
    Zero-copy - shares the same GPU memory.
    """
    dtype_map = {
        'float32': torch.float32,
        'float64': torch.float64,
        'float16': torch.float16,
        'bfloat16': torch.bfloat16,
        'int32': torch.int32,
        'int64': torch.int64,
    }

    # This is simplified - actual implementation needs cudaIpcOpenMemHandle
    # through a custom CUDA extension
    storage = torch.cuda.cudart().cudaIpcOpenMemHandle(ref.ipc_handle)

    return torch.tensor([]).set_(
        source=storage,
        storage_offset=0,
        size=ref.shape,
        stride=ref.strides
    ).to(dtype_map[ref.dtype])

def to_elixir(ref: GPUTensorRef) -> dict:
    """Serializes reference for Elixir."""
    return {
        'ipc_handle': base64.b64encode(ref.ipc_handle).decode('ascii'),
        'shape': list(ref.shape),
        'dtype': ref.dtype,
        'device_id': ref.device_id,
        'byte_size': ref.byte_size,
        'strides': list(ref.strides) if ref.strides else None
    }

def from_elixir(data: dict) -> GPUTensorRef:
    """Deserializes reference from Elixir."""
    return GPUTensorRef(
        ipc_handle=base64.b64decode(data['ipc_handle']),
        shape=tuple(data['shape']),
        dtype=data['dtype'],
        device_id=data['device_id'],
        byte_size=data['byte_size'],
        strides=tuple(data['strides']) if data['strides'] else None
    )
```

## Snakepit Integration

### Updated Execute Protocol

```elixir
defmodule Snakepit.Worker do
  # Existing execute/3 signature extended with zero-copy support

  @spec execute(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation, payload, opts \\ []) do
    # Detect zero-copy eligible arguments
    {payload, zero_copy_refs} = extract_zero_copy_refs(payload)

    # Add zero-copy metadata to payload
    enriched_payload = Map.put(payload, "__zero_copy__", zero_copy_refs)

    # Execute
    result = do_execute(operation, enriched_payload, opts)

    # Handle zero-copy returns
    process_zero_copy_result(result)
  end

  defp extract_zero_copy_refs(payload) do
    # Walk payload, extract TensorRef/GPUTensorRef
    # Replace with placeholders
    # Return {modified_payload, refs_map}
  end
end
```

### Automatic Detection

```elixir
defmodule Snakepit.ZeroCopy.AutoDetect do
  @moduledoc """
  Automatically detects when zero-copy should be used.
  """

  @zero_copy_threshold 1_000_000  # 1MB

  @spec should_use_zero_copy?(term()) :: boolean()
  def should_use_zero_copy?(data) do
    case data do
      binary when is_binary(binary) and byte_size(binary) > @zero_copy_threshold ->
        true

      %Snakepit.ZeroCopy.TensorRef{} ->
        true

      %Snakepit.DLPack.GPUTensorRef{} ->
        true

      %{__struct__: Nx.Tensor} ->
        Nx.size(data) * dtype_size(Nx.type(data)) > @zero_copy_threshold

      _ ->
        false
    end
  end

  defp dtype_size({:f, 32}), do: 4
  defp dtype_size({:f, 64}), do: 8
  defp dtype_size({:s, 32}), do: 4
  defp dtype_size({:s, 64}), do: 8
  defp dtype_size({:u, 8}), do: 1
  defp dtype_size(_), do: 4
end
```

## Configuration

```elixir
config :snakepit, :zero_copy,
  enabled: true,
  threshold_bytes: 1_000_000,
  gpu_enabled: true,
  arrow_enabled: true,
  cleanup_interval_ms: 60_000,
  max_shared_memory_mb: 4096
```

## Performance Targets

| Operation | Current (JSON) | Target (Zero-Copy) | Improvement |
|-----------|---------------|-------------------|-------------|
| 1MB array transfer | ~50ms | <100μs | 500x |
| 100MB array transfer | ~5s | <1ms | 5000x |
| 1GB tensor pass-through | ~60s | <10ms | 6000x |
| GPU tensor exchange | N/A | <50μs | - |

## Safety Considerations

### Memory Lifetime

1. **Reference Counting**: Track references on both Elixir and Python sides
2. **Explicit Release**: Provide `release/1` API for deterministic cleanup
3. **Finalizers**: Use ErlNif resource destructors as safety net

### GPU Memory

1. **Device Affinity**: Ensure tensors stay on correct GPU
2. **CUDA Context**: Handle multi-GPU scenarios correctly
3. **OOM Handling**: Graceful fallback to CPU when GPU memory exhausted

### Error Handling

```elixir
defmodule Snakepit.ZeroCopy.Error do
  defexception [:type, :message, :details]

  @type t :: %__MODULE__{
    type: :allocation_failed | :mmap_failed | :cuda_error | :shape_mismatch,
    message: String.t(),
    details: map()
  }
end
```

## Implementation Phases

### Phase 1: CPU Shared Memory (Week 1-2)
- [ ] Implement NIF for POSIX shared memory
- [ ] Elixir API for allocate/release
- [ ] Python bridge for NumPy arrays
- [ ] Basic tests

### Phase 2: Arrow Integration (Week 3-4)
- [ ] Arrow IPC serialization
- [ ] Table/RecordBatch support
- [ ] Pandas/Polars conversion
- [ ] Integration tests

### Phase 3: GPU Support (Week 5-6)
- [ ] CUDA IPC wrapper
- [ ] DLPack protocol
- [ ] PyTorch/CuPy integration
- [ ] Multi-GPU support

### Phase 4: Polish (Week 7-8)
- [ ] Auto-detection
- [ ] Performance optimization
- [ ] Documentation
- [ ] Benchmarks

## Dependencies

### Elixir
- `rustler` or raw NIF for shared memory operations
- Optional: `nx` for Nx tensor integration

### Python
- `numpy` (required)
- `pyarrow` (optional, for Arrow support)
- `torch` (optional, for GPU support)
- `cupy` (optional, for CuPy support)

## Testing Strategy

```elixir
defmodule Snakepit.ZeroCopyTest do
  use ExUnit.Case

  describe "CPU shared memory" do
    test "allocate and read back" do
      {:ok, ref} = Snakepit.ZeroCopy.allocate([1000, 1000], :float32)
      assert ref.byte_size == 4_000_000

      :ok = Snakepit.ZeroCopy.release(ref)
    end

    test "round-trip with Python" do
      data = :rand.bytes(1_000_000)
      {:ok, ref} = Snakepit.ZeroCopy.from_binary(data, [1_000_000], :uint8)

      # Call Python to modify
      {:ok, _} = Snakepit.execute("numpy.multiply", %{
        "array" => ref,
        "scalar" => 2
      })

      # Read back
      {:ok, result} = Snakepit.ZeroCopy.to_binary(ref)
      assert byte_size(result) == 1_000_000
    end
  end
end
```

## SnakeBridge Integration Points

SnakeBridge will need to:

1. **Detect large arguments** in generated wrappers
2. **Emit zero-copy calls** when appropriate
3. **Handle TensorRef in type encoding**
4. **Document zero-copy in generated docs**

See: `snakebridge/docs/20251227/world-class-ml/` for integration details.
