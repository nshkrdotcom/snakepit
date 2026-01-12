# Graceful Serialization Fallback for Non-JSON Objects

## Executive Summary

When Snakepit serializes Python return values to send to Elixir, non-JSON-serializable objects (like DSPy's `ModelResponse`, OpenAI's `ChatCompletion`, etc.) cause the entire serialization to fail. This document specifies a TDD implementation plan for graceful fallback handling.

**The fix belongs in Snakepit, not SnakeBridge or DSPex.**

---

## Why Snakepit, Not SnakeBridge?

### The Serialization Flow

```
Python Function Returns Value (e.g., list of dicts with ModelResponse)
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ SNAKEPIT (Python side)                                          │
│                                                                 │
│ grpc_server.py:633                                              │
│   TypeSerializer.encode_any(result_data, result_type)           │
│       │                                                         │
│       ▼                                                         │
│ serialization.py:176 ◄────── FAILURE POINT (no error handling)  │
│   orjson.dumps(value_to_serialize)  # or json.dumps at 179      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Why Not SnakeBridge?

- **SnakeBridge receives already-serialized JSON from Snakepit** - It can't recover data that Python failed to serialize
- **The failure happens in Python** - `json.dumps()` raises TypeError before data leaves for Elixir

### Why Not DSPex?

The problem affects ALL Python libraries, not just DSPy. Central fix in Snakepit benefits everyone.

---

## TDD Implementation Plan

### Phase 1: Write Failing Tests First

#### Step 1.1: Create Python Test File

Create `/home/home/p/g/n/snakepit/test/python/test_graceful_serialization.py`:

```python
"""Tests for graceful serialization fallback - written BEFORE implementation."""

import pytest
import json
from datetime import datetime

# These imports will fail until we implement the feature
from snakepit_bridge.serialization import (
    TypeSerializer,
    GracefulJSONEncoder,
    _orjson_default
)


class CustomObject:
    """Non-serializable test object."""
    def __init__(self, value):
        self.value = value

    def __repr__(self):
        return f"CustomObject({self.value!r})"


class PydanticLike:
    """Object with model_dump method."""
    def __init__(self, data):
        self.data = data

    def model_dump(self):
        return {"data": self.data}


class DictConvertible:
    """Object with to_dict method."""
    def __init__(self, x):
        self.x = x

    def to_dict(self):
        return {"x": self.x}


class TestGracefulJSONEncoder:
    """Test stdlib json encoder with graceful fallback."""

    def test_basic_types_unchanged(self):
        """Basic JSON types serialize normally."""
        data = {"string": "hello", "number": 42, "list": [1, 2, 3]}
        result = json.dumps(data, cls=GracefulJSONEncoder)
        assert json.loads(result) == data

    def test_datetime_uses_isoformat(self):
        """Datetime objects converted via isoformat."""
        dt = datetime(2026, 1, 11, 10, 30, 0)
        result = json.dumps({"time": dt}, cls=GracefulJSONEncoder)
        assert json.loads(result)["time"] == "2026-01-11T10:30:00"

    def test_model_dump_method_used(self):
        """Objects with model_dump() are converted."""
        obj = PydanticLike("test")
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == {"data": "test"}

    def test_to_dict_method_used(self):
        """Objects with to_dict() are converted."""
        obj = DictConvertible(42)
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == {"x": 42}

    def test_fallback_creates_marker(self):
        """Non-convertible objects get unserializable marker."""
        obj = CustomObject("test")
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)["obj"]

        assert parsed["__snakepit_unserializable__"] is True
        assert "CustomObject" in parsed["__type__"]
        assert "CustomObject('test')" in parsed["__repr__"]

    def test_nested_unserializable_handled(self):
        """Nested unserializable objects in lists/dicts are handled."""
        data = {"items": [1, CustomObject("a"), 3]}
        result = json.dumps(data, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        assert parsed["items"][0] == 1
        assert parsed["items"][1]["__snakepit_unserializable__"] is True
        assert parsed["items"][2] == 3


class TestTypeSerializerIntegration:
    """Integration tests with TypeSerializer."""

    def test_list_with_unserializable_succeeds(self):
        """TypeSerializer handles lists containing unserializable items."""
        data = [1, "two", CustomObject("three")]
        # Should NOT raise - graceful fallback
        any_msg, binary_data = TypeSerializer.encode_any(data, "list")
        assert any_msg is not None

    def test_dict_with_unserializable_succeeds(self):
        """TypeSerializer handles dicts with unserializable values."""
        data = {"good": 123, "bad": CustomObject("value")}
        # Should NOT raise - graceful fallback
        any_msg, binary_data = TypeSerializer.encode_any(data, "map")
        assert any_msg is not None
```

Run tests to confirm they fail:

```bash
cd /home/home/p/g/n/snakepit
python -m pytest test/python/test_graceful_serialization.py -v
# Expected: ImportError or test failures
```

#### Step 1.2: Create Elixir Integration Test

Create `/home/home/p/g/n/snakepit/test/graceful_serialization_test.exs`:

```elixir
defmodule Snakepit.GracefulSerializationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    Application.ensure_all_started(:snakepit)
    :ok
  end

  describe "graceful serialization" do
    test "returns data even when some fields are unserializable" do
      # Call Python code that returns a list with a non-serializable object
      {:ok, result} =
        Snakepit.execute(:default, "builtins", "eval", [
          "[1, datetime.datetime.now(), 3]",
          %{"datetime" => :__import_datetime__}
        ])

      # datetime should be converted to ISO string, not fail
      assert is_list(result)
      assert length(result) == 3
      assert Enum.at(result, 0) == 1
      assert is_binary(Enum.at(result, 1))  # ISO format string
      assert Enum.at(result, 2) == 3
    end

    test "custom objects get unserializable marker" do
      # Define and instantiate a custom class
      code = """
      class Foo:
          def __init__(self):
              self.x = 1
          def __repr__(self):
              return "Foo()"
      {"obj": Foo(), "num": 42}
      """

      {:ok, result} = Snakepit.execute(:default, "builtins", "eval", [code])

      assert result["num"] == 42
      assert result["obj"]["__snakepit_unserializable__"] == true
      assert String.contains?(result["obj"]["__type__"], "Foo")
    end
  end
end
```

---

### Phase 2: Implement the Feature

#### Step 2.1: Add GracefulJSONEncoder to serialization.py

File: `/home/home/p/g/n/snakepit/priv/python/snakepit_bridge/serialization.py`

Add after line 20 (after imports):

```python
class GracefulJSONEncoder(json.JSONEncoder):
    """JSON encoder that gracefully handles non-serializable objects."""

    def default(self, obj):
        # Try common conversion methods first
        for method in ('model_dump', 'to_dict', '_asdict', 'tolist'):
            if hasattr(obj, method):
                try:
                    return getattr(obj, method)()
                except Exception:
                    pass

        if hasattr(obj, 'isoformat'):
            try:
                return obj.isoformat()
            except Exception:
                pass

        # Fallback: unserializable marker
        return {
            "__snakepit_unserializable__": True,
            "__type__": f"{type(obj).__module__}.{type(obj).__name__}",
            "__repr__": repr(obj)[:500]
        }


def _orjson_default(obj):
    """Default handler for orjson (same logic as GracefulJSONEncoder)."""
    for method in ('model_dump', 'to_dict', '_asdict', 'tolist'):
        if hasattr(obj, method):
            try:
                return getattr(obj, method)()
            except Exception:
                pass

    if hasattr(obj, 'isoformat'):
        try:
            return obj.isoformat()
        except Exception:
            pass

    return {
        "__snakepit_unserializable__": True,
        "__type__": f"{type(obj).__module__}.{type(obj).__name__}",
        "__repr__": repr(obj)[:500]
    }
```

#### Step 2.2: Modify _serialize_value Method

Replace lines 174-179 in `_serialize_value`:

```python
# Use orjson if available, otherwise stdlib json
if _use_orjson:
    return orjson.dumps(value_to_serialize, default=_orjson_default)
else:
    return json.dumps(value_to_serialize, cls=GracefulJSONEncoder).encode('utf-8')
```

---

### Phase 3: Run Tests (Should Pass)

```bash
# Python unit tests
cd /home/home/p/g/n/snakepit
python -m pytest test/python/test_graceful_serialization.py -v

# Elixir integration tests
mix test test/graceful_serialization_test.exs
```

---

### Phase 4: Add Example

#### Step 4.1: Create Example File

Create `/home/home/p/g/n/snakepit/examples/graceful_serialization.exs`:

```elixir
# Graceful Serialization Demo
#
# Demonstrates how Snakepit handles non-JSON-serializable Python objects
# by converting them gracefully instead of failing.
#
# Run with: mix run --no-start examples/graceful_serialization.exs

defmodule GracefulSerializationDemo do
  @moduledoc false

  def run do
    IO.puts("Graceful Serialization Demo")
    IO.puts(String.duplicate("=", 50))

    configure_snakepit()

    Snakepit.run_as_script(fn ->
      demo_datetime()
      demo_custom_class()
      demo_mixed_list()
      demo_nested_structure()

      IO.puts("\nAll demos completed successfully!")
    end)
  end

  defp configure_snakepit do
    Application.put_env(:snakepit, :pools, [
      %{name: :default, pool_size: 2, affinity: :none}
    ])
  end

  defp demo_datetime do
    IO.puts("\n--- Demo 1: datetime objects ---")

    # datetime.datetime is not JSON serializable by default
    # Snakepit converts it via isoformat()
    {:ok, result} = Snakepit.execute(:default, "builtins", "eval", [
      "{'now': __import__('datetime').datetime.now(), 'number': 42}"
    ])

    IO.puts("Result: #{inspect(result)}")
    IO.puts("Timestamp: #{result["now"]}")
    IO.puts("Number: #{result["number"]}")
  end

  defp demo_custom_class do
    IO.puts("\n--- Demo 2: Custom class (unserializable) ---")

    # Custom classes without conversion methods get marker
    code = """
class Response:
    def __init__(self, status, data):
        self.status = status
        self.data = data
    def __repr__(self):
        return f"Response(status={self.status})"

{"response": Response(200, "secret"), "message": "hello"}
"""

    {:ok, result} = Snakepit.execute(:default, "builtins", "eval", [code])

    IO.puts("Result: #{inspect(result)}")
    IO.puts("Message (preserved): #{result["message"]}")
    IO.puts("Response type: #{result["response"]["__type__"]}")
    IO.puts("Response repr: #{result["response"]["__repr__"]}")
  end

  defp demo_mixed_list do
    IO.puts("\n--- Demo 3: Mixed list with unserializable items ---")

    code = """
import datetime

class Widget:
    pass

[1, "two", datetime.date.today(), Widget(), 5]
"""

    {:ok, result} = Snakepit.execute(:default, "builtins", "eval", [code])

    IO.puts("Result: #{inspect(result)}")
    IO.puts("Item 0 (int): #{Enum.at(result, 0)}")
    IO.puts("Item 1 (str): #{Enum.at(result, 1)}")
    IO.puts("Item 2 (date): #{Enum.at(result, 2)}")
    IO.puts("Item 3 (Widget): #{inspect(Enum.at(result, 3))}")
    IO.puts("Item 4 (int): #{Enum.at(result, 4)}")
  end

  defp demo_nested_structure do
    IO.puts("\n--- Demo 4: Nested structure (simulates DSPy history) ---")

    # Simulates the DSPy GLOBAL_HISTORY problem
    code = """
import datetime

class ModelResponse:
    def __init__(self, id):
        self.id = id
    def __repr__(self):
        return f"ModelResponse(id={self.id!r})"

# Structure like DSPy's GLOBAL_HISTORY
[
    {
        "model": "gpt-4",
        "cost": 0.001,
        "timestamp": datetime.datetime.now().isoformat(),
        "messages": [{"role": "user", "content": "Hello"}],
        "outputs": ["Hi there!"],
        "response": ModelResponse("chat-123")  # Non-serializable!
    }
]
"""

    {:ok, result} = Snakepit.execute(:default, "builtins", "eval", [code])

    entry = List.first(result)
    IO.puts("Result: #{inspect(result, pretty: true, limit: :infinity)}")
    IO.puts("\nPreserved fields:")
    IO.puts("  model: #{entry["model"]}")
    IO.puts("  cost: #{entry["cost"]}")
    IO.puts("  messages: #{inspect(entry["messages"])}")
    IO.puts("  outputs: #{inspect(entry["outputs"])}")
    IO.puts("\nGracefully handled:")
    IO.puts("  response.__type__: #{entry["response"]["__type__"]}")
    IO.puts("  response.__repr__: #{entry["response"]["__repr__"]}")
  end
end

GracefulSerializationDemo.run()
```

#### Step 4.2: Update run_all.sh

Add to the EXAMPLE_SCRIPTS array (around line 118):

```bash
  # Serialization
  "examples/graceful_serialization.exs"
```

#### Step 4.3: Update README.md

Add section after existing categories:

```markdown
### 🔄 Serialization

#### `graceful_serialization.exs`
**Graceful handling of non-JSON-serializable Python objects**
- datetime/date objects converted via isoformat()
- Objects with model_dump()/to_dict() are converted
- Custom objects get unserializable markers with type info
- Nested structures preserve all serializable data

```bash
mix run --no-start examples/graceful_serialization.exs
```
```

---

## Implementation Checklist

### TDD Phase (Done)
- [x] Create `priv/python/tests/test_graceful_serialization.py` (24 tests)
- [x] Run tests, confirm implementation works

### Implementation Phase (Done)
- [x] Add `GracefulJSONEncoder` class to `serialization.py`
- [x] Add `_orjson_default` function to `serialization.py`
- [x] Modify `_serialize_value` to use graceful encoding
- [x] Run tests, all 24 pass

### Example Phase (Done)
- [x] Add `serialization_demo` tool to showcase adapter
- [x] Create `examples/graceful_serialization.exs`
- [x] Add to `examples/run_all.sh` EXAMPLE_SCRIPTS array
- [x] Add to `examples/README.md`
- [x] Run example manually - works perfectly

### Finalize
- [ ] Run full test suite: `mix test`
- [ ] Run all examples: `./examples/run_all.sh`
- [ ] Update CHANGELOG

---

## DSPex Changes After Fix

Once Snakepit is released with this fix, update DSPex:

**File:** `/home/home/p/g/n/DSPex/examples/flagship_multi_pool_gepa.exs`

```elixir
defp print_prompt_history(label, session) do
  runtime_opts = runtime(session.pool, session.session_id)

  IO.puts("  #{label} (last 6 calls):")

  # Now works! GLOBAL_HISTORY serializes with graceful fallback
  {:ok, base_lm} = DSPex.call("importlib", "import_module", ["dspy.clients.base_lm"], __runtime__: runtime_opts)
  {:ok, history} = DSPex.attr(base_lm, "GLOBAL_HISTORY", __runtime__: runtime_opts)

  history
  |> Enum.take(-6)
  |> Enum.each(fn entry ->
    model = entry["model"] || "unknown"
    cost = entry["cost"]
    # response field has marker, but all other fields are usable
    IO.puts("    #{model} (cost: $#{cost})")
  end)
end
```

No changes needed to `lib/dspex.ex` - it's a thin FFI wrapper.
