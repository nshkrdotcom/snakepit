# 04 - Exception Translation (Magic Mirror)

## Goal

Convert Python exceptions into structured Elixir errors that are pattern-matchable and ergonomic.

## Error Structs

Snakepit exposes a base error struct and specific exception structs:

```elixir
defmodule Snakepit.Error do
  @type t :: %__MODULE__{type: atom(), message: String.t(), context: map()}
  defstruct [:type, :message, context: %{}]
end

# Example specific error

defmodule Snakepit.Error.ValueError do
  defexception [:message, :context, :stacktrace]
end
```

## Python Adapter Output

Python adapter should return structured error payloads:

```json
{
  "ok": false,
  "error": {
    "type": "ValueError",
    "message": "shapes (3,4) and (2,2) not aligned",
    "stacktrace": ["..."] ,
    "context": {"shape_a": [3,4], "shape_b": [2,2]}
  }
}
```

## Mapping Strategy

- Use a built-in map for common exceptions (ValueError, KeyError, IndexError, TypeError).
- Allow metadata packages to provide extended mappings per library/version.
- Unknown exceptions map to `Snakepit.Error.PythonException`.

## Callsite Context

When possible, attach:

- Elixir module/function callsite
- argument shapes/dtypes (if available)
- library and function name

## Example

```elixir
case Numpy.dot(a, b) do
  {:ok, result} -> result
  {:error, %Snakepit.Error.ValueError{} = err} ->
    handle_shape_mismatch(err)
end
```

## Testing

- Unit tests for exception mapping
- Integration tests that trigger TypeError and ValueError
- Verify unknown exception maps to generic struct

