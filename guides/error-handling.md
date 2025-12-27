# Error Handling

Snakepit provides structured exceptions for ML workloads with
automatic parsing of Python errors.

## Error Types

### Shape Mismatch

```elixir
# Create shape error
error = Snakepit.Error.Shape.shape_mismatch(
  [3, 224, 224],  # expected
  [3, 256, 256],  # got
  "conv2d"        # operation
)

# Pattern match
case result do
  {:error, %Snakepit.Error.ShapeMismatch{dimension: dim}} ->
    Logger.error("Mismatch at dimension #{dim}")
end
```

### Device Mismatch

```elixir
# Create device error
error = Snakepit.Error.Device.device_mismatch(
  :cpu,        # expected
  {:cuda, 0},  # got
  "matmul"     # operation
)

# Pattern match
case result do
  {:error, %Snakepit.Error.DeviceMismatch{expected: exp, got: got}} ->
    Logger.error("Device mismatch: expected #{exp}, got #{got}")
end
```

### Out of Memory

```elixir
# OOM errors include recovery suggestions
error = Snakepit.Error.Device.out_of_memory(
  {:cuda, 0},
  1024 * 1024 * 1024,  # requested: 1GB
  512 * 1024 * 1024    # available: 512MB
)

error.suggestions
# => ["Reduce batch size", "Use gradient checkpointing", ...]
```

## Parsing Python Errors

The parser automatically detects error patterns:

```elixir
# Parse from raw error data
{:ok, error} = Snakepit.Error.Parser.parse(%{
  "type" => "RuntimeError",
  "message" => "shape mismatch: expected [3, 224, 224], got [3, 256, 256]"
})

# Returns ShapeMismatch with extracted shapes
%Snakepit.Error.ShapeMismatch{
  expected: [3, 224, 224],
  got: [3, 256, 256]
} = error
```

### Supported Patterns

The parser detects these patterns:

- **Shape mismatch**: "expected [1, 2], got [3, 4]"
- **CUDA OOM**: "CUDA out of memory. Tried to allocate 2.00 GiB"
- **Device mismatch**: "Expected all tensors on same device"

### From gRPC Errors

```elixir
{:ok, error} = Snakepit.Error.Parser.from_grpc_error(%{
  status: :internal,
  message: "ValueError: Invalid input"
})
```

## Python Exception Types

Standard Python exceptions are mapped to Elixir structs:

| Python | Elixir |
|--------|--------|
| `ValueError` | `Snakepit.Error.ValueError` |
| `TypeError` | `Snakepit.Error.TypeError` |
| `KeyError` | `Snakepit.Error.KeyError` |
| `RuntimeError` | `Snakepit.Error.RuntimeError` |
| `ImportError` | `Snakepit.Error.ImportError` |

```elixir
case result do
  {:error, %Snakepit.Error.ValueError{message: msg}} ->
    Logger.error("Invalid value: #{msg}")

  {:error, %Snakepit.Error.TypeError{message: msg}} ->
    Logger.error("Type error: #{msg}")
end
```

## Telemetry Events

Error creation emits telemetry:

```elixir
:telemetry.attach(
  "error-handler",
  [:snakepit, :error, :shape_mismatch],
  fn _event, _measurements, metadata, _config ->
    Logger.warning(
      "Shape mismatch in #{metadata.operation}: " <>
      "expected #{inspect(metadata.expected)}, got #{inspect(metadata.got)}"
    )
  end,
  nil
)
```

Available events:
- `[:snakepit, :error, :shape_mismatch]`
- `[:snakepit, :error, :device]`
- `[:snakepit, :error, :oom]`
- `[:snakepit, :error, :dtype_mismatch]`
