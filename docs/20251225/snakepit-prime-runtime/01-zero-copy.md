# 01 - Zero-Copy Interop (DLPack + Arrow)

## Goal

Allow large tensors and tables to cross the Elixir/Python boundary without serialization or memory copies, using established interchange standards.

## Standards

- **DLPack** for tensors (CPU/GPU)
- **Apache Arrow** for columnar/tabular data

These are widely supported in PyTorch, JAX, CuPy, NumPy, Pandas, Polars, and PyArrow.

## Elixir API (Proposed)

```elixir
# DLPack tensor interop
{:ok, dlpack} = Snakepit.ZeroCopy.to_dlpack(nx_tensor)
{:ok, nx_tensor} = Snakepit.ZeroCopy.from_dlpack(dlpack)

# Arrow table interop
{:ok, arrow_ref} = Snakepit.ZeroCopy.to_arrow(table)
{:ok, table} = Snakepit.ZeroCopy.from_arrow(arrow_ref)

# Explicit cleanup
:ok = Snakepit.ZeroCopy.close(dlpack)
:ok = Snakepit.ZeroCopy.close(arrow_ref)
```

## Handle Types

```elixir
@type Snakepit.ZeroCopyRef.t :: %Snakepit.ZeroCopyRef{
  kind: :dlpack | :arrow,
  device: :cpu | :cuda | :mps,
  dtype: atom(),
  shape: tuple() | nil,
  owner: :elixir | :python,
  ref: reference()
}
```

- `owner` determines which side is responsible for freeing the memory.
- `ref` is an opaque handle understood by Snakepit and the Python adapter.

## Ownership and Lifetime

Rules:

1. **Elixir-owned** buffers must be explicitly released (or via finalizer) when Python no longer needs them.
2. **Python-owned** buffers are referenced by Elixir; `close/1` releases the Elixir handle only.
3. If a buffer cannot be shared, Snakepit performs a copy and marks the handle as `copy: true` in metadata.

## Transport and Adapter Contract

Zero-copy handles travel through the same `snakebridge.call` payloads as any other argument. The Python adapter detects the handle and converts it to a native tensor or table using DLPack/Arrow.

Example payload:

```elixir
%{
  library: "numpy",
  python_module: "numpy",
  function: "mean",
  args: [%Snakepit.ZeroCopyRef{kind: :dlpack, ...}],
  kwargs: %{}
}
```

## Implementation Notes

### DLPack

- Use a small C NIF to wrap/unpack DLPack capsules safely.
- The NIF must only manage memory handles; it must not embed or link Python.
- Use `dlpack` crates or vendored headers for safety and reproducibility.

### Arrow

- Use Arrow C Data Interface for zero-copy buffer exchange.
- On platforms without `memfd` (Linux), fall back to mmap files or shared memory where available.

## Fallback Behavior

If zero-copy is not supported for a given type or device:

- Log a warning with a stable reason code (`:zero_copy_unavailable`).
- Copy the data and continue, preserving functional correctness.

## Telemetry

Emit the following events:

- `[:snakepit, :zero_copy, :export]` (bytes, kind, device)
- `[:snakepit, :zero_copy, :import]`
- `[:snakepit, :zero_copy, :fallback]`

## Testing

- Unit tests for handle creation and release.
- Integration tests with NumPy and PyTorch (CPU).
- Optional GPU test suite gated by `SNAKEPIT_GPU_TESTS=true`.

