# Graceful Serialization

Snakepit gracefully handles Python objects that cannot be serialized to JSON. Instead of
failing with serialization errors, non-serializable objects are replaced with informative
markers containing type information.

This enables returning partial data even when some fields contain non-serializable objects
like `datetime.datetime`, custom classes, or library-specific response objects.

## How It Works

When Python returns data to Elixir, the serialization layer processes each value:

1. **JSON-serializable values** pass through unchanged (strings, numbers, lists, dicts, booleans, None)

2. **Objects with conversion methods** are automatically converted by calling the first available method:
   - `model_dump()` - returns a dict representation
   - `to_dict()` - returns a dict representation
   - `_asdict()` - returns a dict representation (named tuples)
   - `tolist()` - returns a list representation (arrays, with size guards)
   - `isoformat()` - returns an ISO 8601 string (datetime/date objects)

3. **Non-convertible objects** become marker maps with type information

The system uses **duck typing** - it checks if methods exist, not what class the object is.
Any object with `to_dict()` will be converted, regardless of what library it comes from.

## Using the Elixir Helpers

Check for and inspect unserializable markers using the `Snakepit.Serialization` module:

```elixir
# Execute Python code that returns mixed data
{:ok, result} = Snakepit.execute("get_data", %{})

# Check if a specific field is an unserializable marker
if Snakepit.Serialization.unserializable?(result["response"]) do
  {:ok, info} = Snakepit.Serialization.unserializable_info(result["response"])

  IO.puts("Type: #{info.type}")
  # => "mymodule.MyClass"

  IO.puts("Repr: #{info.repr || "(not included)"}")
  # Only present if detail mode is enabled
end
```

### Walking Complex Structures

For nested structures, you may need to walk the data recursively:

```elixir
defmodule MyApp.DataProcessor do
  def process(data) when is_map(data) do
    if Snakepit.Serialization.unserializable?(data) do
      {:ok, info} = Snakepit.Serialization.unserializable_info(data)
      {:unserializable, info.type}
    else
      Map.new(data, fn {k, v} -> {k, process(v)} end)
    end
  end

  def process(data) when is_list(data) do
    Enum.map(data, &process/1)
  end

  def process(data), do: data
end
```

## Marker Format

Unserializable markers have this structure:

```elixir
%{
  "__ffi_unserializable__" => true,
  "__type__" => "module.ClassName"
}
```

When detail mode is enabled, an additional `__repr__` field may be present:

```elixir
%{
  "__ffi_unserializable__" => true,
  "__type__" => "datetime.datetime",
  "__repr__" => "datetime.datetime(2024, 1, 11, 10, 30)"
}
```

## Configuration

### Detail Modes

Control what information is included in markers via the `SNAKEPIT_UNSERIALIZABLE_DETAIL`
environment variable. This must be set **before starting Snakepit** since Python workers
inherit environment from the BEAM VM.

```elixir
# In config/runtime.exs or application startup
System.put_env("SNAKEPIT_UNSERIALIZABLE_DETAIL", "repr_redacted_truncated")
```

Available modes:

| Mode | Description | Production Safe? |
|------|-------------|------------------|
| `none` (default) | Only type, no repr | Yes |
| `type` | Placeholder string with type name | Yes |
| `repr_truncated` | Include truncated repr | No - may leak secrets |
| `repr_redacted_truncated` | Truncated repr with common secrets redacted | Mostly - best effort |

### Repr Length Limit

When repr is enabled, limit its length:

```elixir
System.put_env("SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN", "200")
```

- Default: 500 characters
- Maximum: 2000 characters (values above this are clamped)

### Tolist Size Guard

The `tolist()` method on arrays can expand data explosively (e.g., sparse to dense conversion).
Snakepit guards against this in two ways:

1. **Pre-check for known types**: Size is checked **before** calling `tolist()` to prevent
   the allocation from happening at all:
   - **numpy.ndarray**: Precise detection via `isinstance()`
   - **scipy sparse matrices**: Best-effort heuristic using `nnz` + `shape` attributes
   - **pandas DataFrame/Series**: Best-effort heuristic using `size` + `values` attributes

2. **Post-check for unknown types**: For objects with `tolist()` that we can't pre-inspect,
   the method is called and the result size is checked. If too large, it falls back to a
   marker. Note: this means unknown types may still allocate before the fallback.

```elixir
System.put_env("SNAKEPIT_TOLIST_MAX_ELEMENTS", "100000")
```

- Default: 1,000,000 elements (~8MB for floats)
- Lists exceeding this fall back to markers

**What this protects against:**
- Transmission of huge payloads over gRPC
- Memory usage on the Elixir side

**What this does NOT fully protect against:**
- Memory allocation within Python for unknown types (they may allocate before we can check)

### Example Configuration

```elixir
# config/runtime.exs
import Config

# Development: enable repr with redaction for debugging
if config_env() == :dev do
  System.put_env("SNAKEPIT_UNSERIALIZABLE_DETAIL", "repr_redacted_truncated")
  System.put_env("SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN", "200")
end

# Production: use safe defaults (no repr)
# No env vars needed - defaults are safe
```

## Secret Redaction

When using `repr_redacted_truncated` mode, common secret patterns are redacted:

- API keys matching `sk-...` pattern
- Bearer tokens
- JSON-style credentials (`"api_key": "..."`, `"password": "..."`, etc.)

**Important**: Redaction is best-effort, not a security boundary. It catches common patterns
but cannot guarantee all secrets are removed.

Example:

```python
# Python object with secrets in repr
class APIClient:
    def __repr__(self):
        return f"APIClient(api_key='sk-abc123xyz789', token='Bearer eyJ...')"
```

With `repr_redacted_truncated`:
```elixir
%{
  "__ffi_unserializable__" => true,
  "__type__" => "__main__.APIClient",
  "__repr__" => "APIClient(api_key='sk-<REDACTED>', token='Bearer <REDACTED>')"
}
```

## Telemetry

Marker creation emits telemetry events for observability. Events are **deduplicated per type
per process** to avoid high cardinality in metrics backends:

```elixir
:telemetry.attach("marker-stats", [:snakepit, :serialization, :unserializable_marker], fn
  _event, %{first_seen: 1}, %{type: type}, _config ->
    Logger.debug("First unserializable marker for type: #{type}")
end, nil)
```

Key properties:
- **`first_seen` measurement**: Indicates first occurrence of this type (not a volume counter)
- **Type-only metadata**: Never includes repr to avoid leaking secrets into logs
- **Deduplicated**: Each unique type emits only once per worker process
- **Capped at 10,000 types**: Once the cap is reached, new types are silently skipped to bound
  both memory and telemetry cardinality
- **Best-effort**: Telemetry errors never break serialization

**Note**: Since events are deduplicated and capped, you cannot use this to count total markers
created. Use it to track "types seen" for debugging, not volume metrics.

## Examples

### Objects with Conversion Methods

If an object has `to_dict()`, `model_dump()`, or similar, it converts automatically:

```python
class MyResponse:
    def __init__(self, data, status):
        self.data = data
        self.status = status

    def to_dict(self):
        return {"data": self.data, "status": self.status}

return {"response": MyResponse("hello", 200)}
# Elixir receives: %{"response" => %{"data" => "hello", "status" => 200}}
```

### Custom Classes Without Conversion

Classes without conversion methods become markers:

```python
class DatabaseConnection:
    def __init__(self, host, port):
        self.host = host
        self.port = port

return {"connection": DatabaseConnection("localhost", 5432)}
```

In Elixir:
```elixir
{:ok, %{"connection" => conn}} = Snakepit.execute("get_connection", %{})

Snakepit.Serialization.unserializable?(conn)
# => true

{:ok, info} = Snakepit.Serialization.unserializable_info(conn)
info.type
# => "__main__.DatabaseConnection"
```

### Mixed Structures

Structures with both serializable and non-serializable fields work - serializable data
is preserved, non-serializable objects become markers:

```python
import datetime

class InternalState:
    pass

return {
    "timestamp": datetime.datetime.now(),  # converts via isoformat()
    "count": 42,                            # passes through
    "items": ["a", "b", "c"],               # passes through
    "internal": InternalState()             # becomes marker
}
```

## Best Practices

1. **Use safe defaults in production**: Don't enable repr modes unless needed for debugging

2. **Check for markers when processing responses**: If your Python code might return
   non-serializable objects, check with `unserializable?/1`

3. **Add conversion methods to your classes**: If you control the Python code, add
   `to_dict()` to make objects serializable

4. **Monitor marker creation**: Use telemetry to track when markers are created - excessive
   markers might indicate a serialization issue to fix

5. **Set size guards appropriately**: If you work with large arrays, adjust
   `SNAKEPIT_TOLIST_MAX_ELEMENTS` based on your memory constraints

## API Reference

See `Snakepit.Serialization` module documentation for full API details:

- `Snakepit.Serialization.unserializable?/1` - Check if a value is a marker
- `Snakepit.Serialization.unserializable_info/1` - Extract type and repr from a marker
