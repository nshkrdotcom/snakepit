# Phase 1 Type System MVP - Snakepit Implementation Prompt

## CONTEXT

You are implementing Phase 1 of the type system improvements for Snakepit, a high-performance Elixir library that manages external Python processes via gRPC. Based on comprehensive research (see `../01_typing_geminiDeepResearch.md` and `../02_typing_claudeDeepResearch.md`), Phase 1 focuses on **immediate wins with zero breaking changes**:

1. **6x JSON performance boost** via orjson (Python)
2. **Structured error types** for better debugging
3. **Complete @spec coverage** for Dialyzer analysis

## RESEARCH FINDINGS SUMMARY

From the deep research documents:

> "Keep JSON with optimizations for immediate wins (6x speedup with orjson), adopt Apache Arrow for NumPy/Pandas data (10x faster than pickle), introduce MessagePack for high-frequency internal APIs (2-3x speedup), and reserve Protocol Buffers for mission-critical typed contracts."

**Phase 1 Immediate Wins (1-2 weeks, zero risk):**
1. Upgrade Python to orjson (1 hour) → 6x faster JSON
2. Add @spec to 20 core functions (8 hours) → Dialyzer coverage
3. Create SnakeBridge.Types module (2 hours) → Consistent types
4. Add telemetry events (4 hours) → Observability

**Expected outcome**: 6x faster JSON operations, type documentation, monitoring baseline.

## CURRENT STATE

### Python Serialization (NEEDS IMPROVEMENT)
Location: `priv/python/snakepit_bridge/serialization.py`

Current implementation:
```python
import json  # ❌ Standard library - SLOW
import pickle
import numpy as np
from typing import Any, Dict, Union, Tuple, Optional
from google.protobuf import any_pb2

BINARY_THRESHOLD = 10_240

class TypeSerializer:
    @staticmethod
    def _serialize_value(value: Any, var_type: str) -> str:
        # Handle special float values
        if var_type == 'float':
            if isinstance(value, float):
                if np.isnan(value):
                    return json.dumps("NaN")  # ❌ SLOW
                elif np.isinf(value):
                    return json.dumps("Infinity" if value > 0 else "-Infinity")

        return json.dumps(value)  # ❌ SLOW - used for ALL JSON serialization

    @staticmethod
    def decode_any(any_msg: any_pb2.Any, binary_data: Optional[bytes] = None) -> Any:
        # ...
        json_str = any_msg.value.decode('utf-8')
        value = json.loads(json_str)  # ❌ SLOW - used for ALL JSON deserialization
        # ...
```

### Elixir Error Handling (NEEDS STRUCTURE)
Location: `lib/snakepit/pool/pool.ex`, `lib/snakepit/grpc_worker.ex`

Current implementation returns generic tuples:
```elixir
{:error, :worker_not_found}
{:error, :streaming_not_supported}
{:error, :timeout}
{:error, reason}  # reason is atom or string - NO CONTEXT
```

No traceback from Python exceptions, no structured error details.

### Elixir Type Specs (INCOMPLETE)
Location: `lib/snakepit.ex` (only 3 @spec annotations)

Current state:
```elixir
defmodule Snakepit do
  @moduledoc """..."""

  # ❌ NO @type definitions
  # ❌ NO @spec on most functions

  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
  end

  def execute_in_session(session_id, command, args, opts \\ []) do
    # ...
  end

  # Only ONE @spec in entire module:
  @spec execute_stream(String.t(), map(), function(), keyword()) :: :ok | {:error, term()}
  def execute_stream(command, args \\ %{}, callback_fn, opts \\ []) do
    # ...
  end
end
```

## SOURCE CODE REFERENCE

### Key Files to Modify

#### Python Side
1. **priv/python/requirements.txt** - Add orjson
2. **priv/python/snakepit_bridge/serialization.py** - Replace json with orjson
3. **priv/python/tests/test_serialization.py** - Add performance benchmarks

#### Elixir Side
1. **lib/snakepit/error.ex** - NEW FILE - Structured error type
2. **lib/snakepit.ex** - Add @type and @spec annotations
3. **lib/snakepit/pool/pool.ex** - Update error returns
4. **lib/snakepit/grpc_worker.ex** - Update error returns
5. **test/unit/error_test.exs** - NEW FILE - Test error structs

### Current Test Structure
```
test/
├── snakepit_test.exs                        # Main integration tests
├── unit/
│   ├── grpc/
│   │   ├── grpc_worker_test.exs
│   │   ├── grpc_worker_mock_test.exs
│   │   └── grpc_worker_telemetry_test.exs
│   ├── bridge/
│   │   ├── session_store_test.exs
│   │   └── tool_registry_test.exs
│   └── logger/
│       └── redaction_test.exs

priv/python/tests/
├── test_serialization.py                    # Python serialization tests
├── test_session_context.py
└── test_telemetry.py
```

### Current Dependencies
From `mix.exs`:
```elixir
{:jason, "~> 1.0"},              # Already optimal JSON for Elixir
{:grpc, "~> 0.10.2"},            # gRPC support
{:protobuf, "~> 0.14.1"},        # Protobuf support
{:telemetry_metrics, "~> 1.0"},  # Metrics
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},  # Type checking
```

From `priv/python/requirements.txt`:
```txt
grpcio>=1.60.0
grpcio-tools>=1.60.0
protobuf>=4.25.0
numpy>=1.21.0
psutil>=5.9.0
pytest>=7.0
```

## REQUIREMENTS

### Functional Requirements

1. **FR1: orjson Integration (Python)**
   - Add orjson>=3.9.0 to requirements.txt
   - Replace all json.dumps() with orjson.dumps().decode('utf-8')
   - Replace all json.loads() with orjson.loads()
   - Maintain graceful fallback to stdlib json if orjson not available
   - Zero breaking changes to serialization API

2. **FR2: Structured Error Type (Elixir)**
   - Create `Snakepit.Error` struct with fields:
     - `category`: :worker | :timeout | :python_error | :grpc_error | :validation | :pool
     - `message`: String.t()
     - `details`: map()
     - `python_traceback`: String.t() | nil
     - `grpc_status`: atom() | nil
   - Helper functions for common error types
   - Update all `{:error, atom()}` returns to `{:error, %Snakepit.Error{}}`
   - Maintain backward compatibility by accepting both formats in pattern matches

3. **FR3: Complete Type Specifications (Elixir)**
   - Define @type aliases for common types in `Snakepit` module
   - Add @spec to ALL public functions in:
     - `Snakepit`
     - `Snakepit.Pool`
     - `Snakepit.GRPCWorker`
   - Use structured error type in all @spec definitions
   - Ensure Dialyzer runs without warnings

### Non-Functional Requirements

1. **NFR1: Performance**
   - Minimum 5x JSON speedup (target 6x)
   - No performance regression in any path
   - Benchmark with realistic payloads (1KB, 10KB, 100KB)

2. **NFR2: Backward Compatibility**
   - All existing tests must pass
   - No breaking changes to public APIs
   - Graceful degradation if orjson unavailable

3. **NFR3: Code Quality**
   - No Dialyzer warnings
   - No compiler warnings
   - 100% test coverage on new code
   - Credo/mix format passes

## TEST-DRIVEN DEVELOPMENT PROCESS

### Phase 1: Python orjson Integration

#### Step 1.1: Write Failing Tests (Python)

Create `priv/python/tests/test_orjson_integration.py`:

```python
"""
Test orjson integration for 6x performance improvement.
"""
import pytest
import time
import json
from snakepit_bridge.serialization import TypeSerializer
from google.protobuf import any_pb2

class TestOrjsonIntegration:
    """Test that orjson is properly integrated and provides performance benefits."""

    def test_orjson_available(self):
        """Verify orjson is installed and importable."""
        try:
            import orjson
            assert True
        except ImportError:
            pytest.fail("orjson not installed - run: pip install orjson>=3.9.0")

    def test_serialize_uses_orjson(self):
        """Verify TypeSerializer uses orjson for encoding."""
        # This will be checked by performance benchmark
        pass

    def test_deserialize_uses_orjson(self):
        """Verify TypeSerializer uses orjson for decoding."""
        # This will be checked by performance benchmark
        pass

    def test_json_fallback_graceful(self):
        """Verify graceful fallback to stdlib json if orjson unavailable."""
        # Mock orjson as unavailable
        import sys
        import snakepit_bridge.serialization as serialization_module

        # Temporarily remove orjson
        original_orjson = sys.modules.get('orjson')
        if 'orjson' in sys.modules:
            del sys.modules['orjson']

        # Force reload to trigger fallback
        import importlib
        importlib.reload(serialization_module)

        # Should still work with stdlib json
        value = {"test": "data", "number": 42}
        any_msg, binary_data = TypeSerializer.encode_any(value, "string")
        assert any_msg is not None
        assert binary_data is None

        # Restore orjson
        if original_orjson:
            sys.modules['orjson'] = original_orjson
        importlib.reload(serialization_module)

    @pytest.mark.benchmark
    def test_performance_improvement_small_payload(self):
        """Benchmark: Small payload (1KB) should be 5-6x faster."""
        # Small nested dict
        value = {
            "users": [
                {"id": i, "name": f"user_{i}", "email": f"user{i}@test.com"}
                for i in range(10)
            ],
            "metadata": {"count": 10, "timestamp": "2025-10-28T00:00:00Z"}
        }

        iterations = 1000

        # Benchmark with orjson (current implementation)
        start = time.perf_counter()
        for _ in range(iterations):
            any_msg, _ = TypeSerializer.encode_any(value, "string")
            TypeSerializer.decode_any(any_msg)
        orjson_time = time.perf_counter() - start

        # Benchmark with stdlib json (for comparison)
        start = time.perf_counter()
        for _ in range(iterations):
            json_str = json.dumps(value)
            json.loads(json_str)
        json_time = time.perf_counter() - start

        speedup = json_time / orjson_time

        print(f"\nSmall payload benchmark:")
        print(f"  stdlib json: {json_time:.4f}s")
        print(f"  orjson:      {orjson_time:.4f}s")
        print(f"  speedup:     {speedup:.2f}x")

        # Require at least 5x speedup (target is 6x)
        assert speedup >= 5.0, f"Expected 5x+ speedup, got {speedup:.2f}x"

    @pytest.mark.benchmark
    def test_performance_improvement_large_payload(self):
        """Benchmark: Large payload (100KB) should be 5-6x faster."""
        # Large nested structure
        value = {
            "data": [
                {
                    "id": i,
                    "values": [j * 0.1 for j in range(100)],
                    "metadata": {
                        "tags": [f"tag_{k}" for k in range(10)],
                        "description": f"Item {i} description " * 10
                    }
                }
                for i in range(100)
            ]
        }

        iterations = 100

        # Benchmark with orjson
        start = time.perf_counter()
        for _ in range(iterations):
            any_msg, _ = TypeSerializer.encode_any(value, "string")
            TypeSerializer.decode_any(any_msg)
        orjson_time = time.perf_counter() - start

        # Benchmark with stdlib json
        start = time.perf_counter()
        for _ in range(iterations):
            json_str = json.dumps(value)
            json.loads(json_str)
        json_time = time.perf_counter() - start

        speedup = json_time / orjson_time

        print(f"\nLarge payload benchmark:")
        print(f"  stdlib json: {json_time:.4f}s")
        print(f"  orjson:      {orjson_time:.4f}s")
        print(f"  speedup:     {speedup:.2f}x")

        assert speedup >= 5.0, f"Expected 5x+ speedup, got {speedup:.2f}x"

    def test_special_values_preserved(self):
        """Verify special float values (NaN, Inf) still work correctly."""
        test_cases = [
            (float('nan'), 'float'),
            (float('inf'), 'float'),
            (float('-inf'), 'float'),
        ]

        for value, var_type in test_cases:
            any_msg, binary_data = TypeSerializer.encode_any(value, var_type)
            decoded = TypeSerializer.decode_any(any_msg, binary_data)

            if value != value:  # NaN case
                assert decoded != decoded  # NaN != NaN
            else:
                assert decoded == value
```

#### Step 1.2: Update requirements.txt

Add to `priv/python/requirements.txt`:
```txt
# Phase 1: Performance improvement (6x faster JSON)
orjson>=3.9.0
```

#### Step 1.3: Create Implementation Stub

Update `priv/python/snakepit_bridge/serialization.py`:

```python
"""
Type serialization system for Python side of the bridge.

Supports both JSON and binary serialization for efficient handling
of large numerical data like tensors and embeddings.
"""

# Try to import orjson for 6x performance boost, fallback to stdlib json
try:
    import orjson
    _use_orjson = True
except ImportError:
    import json
    _use_orjson = False

import pickle
import numpy as np
from typing import Any, Dict, Union, Tuple, Optional
from google.protobuf import any_pb2

# Size threshold for using binary serialization (10KB)
BINARY_THRESHOLD = 10_240

class TypeSerializer:
    """Unified type serialization for Python side."""

    @staticmethod
    def encode_any(value: Any, var_type: str) -> Tuple[any_pb2.Any, Optional[bytes]]:
        """
        Encode a Python value to protobuf Any with optional binary data.

        Returns:
            Tuple of (Any message, optional binary data)
        """
        # Normalize value based on type
        normalized = TypeSerializer._normalize_value(value, var_type)

        # Check if we should use binary serialization
        if TypeSerializer._should_use_binary(normalized, var_type):
            return TypeSerializer._encode_with_binary(normalized, var_type)
        else:
            # Standard JSON serialization (now with orjson!)
            json_str = TypeSerializer._serialize_value(normalized, var_type)

            # Create Any message
            any_msg = any_pb2.Any()
            any_msg.type_url = f"type.googleapis.com/snakepit.{var_type}"
            any_msg.value = json_str.encode('utf-8')

            return any_msg, None

    @staticmethod
    def decode_any(any_msg: any_pb2.Any, binary_data: Optional[bytes] = None) -> Any:
        """
        Decode protobuf Any to Python value with optional binary data.

        Args:
            any_msg: Protobuf Any message
            binary_data: Optional binary data for large values

        Returns:
            Decoded Python value
        """
        # Check if this is a binary-encoded value
        if any_msg.type_url.endswith('.binary') and binary_data is not None:
            return TypeSerializer._decode_with_binary(any_msg, binary_data)
        else:
            # Standard JSON decoding (now with orjson!)
            # Extract type from URL
            type_url = any_msg.type_url
            if '/' in type_url:
                type_part = type_url.split('/')[-1]
            else:
                type_part = type_url
            var_type = type_part.split('.')[-1]

            # Decode JSON
            json_str = any_msg.value.decode('utf-8')
            value = TypeSerializer._deserialize_json(json_str)

            # Convert to appropriate Python type
            return TypeSerializer._deserialize_value(value, var_type)

    @staticmethod
    def _normalize_value(value: Any, var_type: str) -> Any:
        """Normalize Python values for consistency."""
        # ... existing implementation unchanged ...
        if var_type == 'float':
            if isinstance(value, (int, float)):
                return float(value)
            raise ValueError(f"Expected number, got {type(value)}")

        elif var_type == 'integer':
            if isinstance(value, (int, float)):
                if isinstance(value, float) and value.is_integer():
                    return int(value)
                elif isinstance(value, int):
                    return value
            raise ValueError(f"Expected integer, got {value}")

        elif var_type == 'string':
            return str(value)

        elif var_type == 'boolean':
            if isinstance(value, bool):
                return value
            raise ValueError(f"Expected boolean, got {type(value)}")

        elif var_type == 'choice':
            return str(value)

        elif var_type == 'module':
            return str(value)

        elif var_type == 'embedding':
            if isinstance(value, np.ndarray):
                return value.tolist()
            elif isinstance(value, list):
                return [float(x) for x in value]
            raise ValueError(f"Expected array/list, got {type(value)}")

        elif var_type == 'tensor':
            if isinstance(value, np.ndarray):
                return {
                    'shape': list(value.shape),
                    'data': value.tolist()
                }
            elif isinstance(value, dict) and 'shape' in value and 'data' in value:
                return value
            raise ValueError(f"Expected tensor, got {type(value)}")

        else:
            return value

    @staticmethod
    def _serialize_value(value: Any, var_type: str) -> str:
        """
        Serialize normalized value to JSON string.

        Uses orjson for 6x performance boost if available,
        falls back to stdlib json otherwise.
        """
        # Handle special float values
        if var_type == 'float':
            if isinstance(value, float):
                if np.isnan(value):
                    value_to_serialize = "NaN"
                elif np.isinf(value):
                    value_to_serialize = "Infinity" if value > 0 else "-Infinity"
                else:
                    value_to_serialize = value
            else:
                value_to_serialize = value
        else:
            value_to_serialize = value

        # Use orjson if available, otherwise stdlib json
        if _use_orjson:
            # orjson returns bytes, must decode to str
            return orjson.dumps(value_to_serialize).decode('utf-8')
        else:
            return json.dumps(value_to_serialize)

    @staticmethod
    def _deserialize_json(json_str: str) -> Any:
        """
        Deserialize JSON string to Python value.

        Uses orjson for 6x performance boost if available,
        falls back to stdlib json otherwise.
        """
        if _use_orjson:
            # orjson.loads accepts str or bytes
            return orjson.loads(json_str)
        else:
            return json.loads(json_str)

    @staticmethod
    def _deserialize_value(value: Any, var_type: str) -> Any:
        """Convert JSON-decoded value to appropriate Python type."""
        # ... existing implementation unchanged ...
        if var_type == 'float':
            if value == "NaN":
                return float('nan')
            elif value == "Infinity":
                return float('inf')
            elif value == "-Infinity":
                return float('-inf')
            return float(value)

        elif var_type == 'integer':
            return int(value)

        elif var_type == 'embedding':
            return value

        elif var_type == 'tensor':
            if isinstance(value, dict) and 'data' in value and 'shape' in value:
                data = np.array(value['data'])
                return data.reshape(value['shape'])
            return value

        else:
            return value

    # ... rest of class unchanged (validate_constraints, _should_use_binary, etc.) ...
```

#### Step 1.4: Run Tests - Confirm Failure

```bash
cd ~/p/g/n/snakepit/priv/python
python -m pytest tests/test_orjson_integration.py -v
```

Expected: Tests fail because orjson not installed yet.

#### Step 1.5: Install Dependencies

```bash
cd ~/p/g/n/snakepit/priv/python
pip install orjson>=3.9.0
```

#### Step 1.6: Run Tests - Confirm Pass

```bash
python -m pytest tests/test_orjson_integration.py -v --tb=short
python -m pytest tests/test_orjson_integration.py::TestOrjsonIntegration::test_performance_improvement_small_payload -v -s
python -m pytest tests/test_orjson_integration.py::TestOrjsonIntegration::test_performance_improvement_large_payload -v -s
```

Expected: All tests pass, benchmarks show 5-6x speedup.

#### Step 1.7: Verify Existing Tests Still Pass

```bash
cd ~/p/g/n/snakepit/priv/python
python -m pytest tests/test_serialization.py -v
```

Expected: All existing serialization tests still pass (backward compatibility).

### Phase 2: Elixir Structured Error Type

#### Step 2.1: Write Failing Tests (Elixir)

Create `test/unit/error_test.exs`:

```elixir
defmodule Snakepit.ErrorTest do
  use ExUnit.Case, async: true

  alias Snakepit.Error

  describe "Error struct" do
    test "has required fields" do
      error = %Error{
        category: :worker,
        message: "Worker not found",
        details: %{worker_id: "worker_1"}
      }

      assert error.category == :worker
      assert error.message == "Worker not found"
      assert error.details == %{worker_id: "worker_1"}
      assert error.python_traceback == nil
      assert error.grpc_status == nil
    end

    test "validates category field" do
      # Valid categories
      valid_categories = [:worker, :timeout, :python_error, :grpc_error, :validation, :pool]

      for category <- valid_categories do
        error = %Error{category: category, message: "test"}
        assert error.category == category
      end
    end
  end

  describe "worker_error/2" do
    test "creates worker error with default details" do
      error = Error.worker_error("Worker crashed")

      assert error.category == :worker
      assert error.message == "Worker crashed"
      assert error.details == %{}
    end

    test "creates worker error with custom details" do
      error = Error.worker_error("Worker not found", %{worker_id: "w1", pool: :default})

      assert error.category == :worker
      assert error.message == "Worker not found"
      assert error.details == %{worker_id: "w1", pool: :default}
    end
  end

  describe "timeout_error/2" do
    test "creates timeout error" do
      error = Error.timeout_error("Request timed out", %{timeout_ms: 5000})

      assert error.category == :timeout
      assert error.message == "Request timed out"
      assert error.details.timeout_ms == 5000
    end
  end

  describe "python_error/4" do
    test "creates Python exception error with traceback" do
      traceback = """
      Traceback (most recent call last):
        File "script.py", line 10, in <module>
          do_something()
        File "script.py", line 5, in do_something
          raise ValueError("Invalid input")
      ValueError: Invalid input
      """

      error = Error.python_error("ValueError", "Invalid input", traceback, %{function: "do_something"})

      assert error.category == :python_error
      assert error.message == "ValueError: Invalid input"
      assert error.python_traceback == traceback
      assert error.details.exception_type == "ValueError"
      assert error.details.function == "do_something"
    end
  end

  describe "grpc_error/3" do
    test "creates gRPC error with status" do
      error = Error.grpc_error(:unavailable, "Service unavailable", %{retry_after: 5})

      assert error.category == :grpc_error
      assert error.message == "Service unavailable"
      assert error.grpc_status == :unavailable
      assert error.details.retry_after == 5
    end
  end

  describe "pool_error/2" do
    test "creates pool error" do
      error = Error.pool_error("Pool not found", %{pool_name: :test_pool})

      assert error.category == :pool
      assert error.message == "Pool not found"
      assert error.details.pool_name == :test_pool
    end
  end

  describe "validation_error/2" do
    test "creates validation error" do
      error = Error.validation_error("Invalid parameters", %{
        field: "user_id",
        expected: "integer",
        got: "string"
      })

      assert error.category == :validation
      assert error.message == "Invalid parameters"
      assert error.details.field == "user_id"
    end
  end

  describe "String.Chars implementation" do
    test "converts error to readable string" do
      error = Error.worker_error("Worker not found", %{worker_id: "w1"})
      string = to_string(error)

      assert string =~ "Worker not found"
      assert string =~ "worker_id"
      assert string =~ "w1"
    end

    test "includes traceback if present" do
      error = Error.python_error("ValueError", "Bad value", "Traceback line 1\nTraceback line 2")
      string = to_string(error)

      assert string =~ "ValueError: Bad value"
      assert string =~ "Traceback"
    end
  end

  describe "backward compatibility" do
    test "pattern matching works with old and new formats" do
      # Old format
      old_result = {:error, :worker_not_found}

      case old_result do
        {:error, :worker_not_found} -> assert true
        _ -> flunk("Pattern match failed")
      end

      # New format
      new_result = {:error, Error.worker_error("Worker not found")}

      case new_result do
        {:error, %Error{category: :worker}} -> assert true
        _ -> flunk("Pattern match failed")
      end
    end
  end
end
```

#### Step 2.2: Create Implementation Stub

Create `lib/snakepit/error.ex`:

```elixir
defmodule Snakepit.Error do
  @moduledoc """
  Structured error type for Snakepit operations.

  Provides detailed context for debugging cross-language and distributed system issues.

  ## Error Categories

  - `:worker` - Worker process errors (not found, crashed, etc.)
  - `:timeout` - Operation timed out
  - `:python_error` - Exception from Python code
  - `:grpc_error` - gRPC communication error
  - `:validation` - Input validation error
  - `:pool` - Pool management error

  ## Examples

      # Create a worker error
      error = Snakepit.Error.worker_error("Worker not found", %{worker_id: "w1"})

      # Create a Python exception error
      error = Snakepit.Error.python_error(
        "ValueError",
        "Invalid input",
        traceback_string,
        %{function: "process_data"}
      )

      # Pattern match in your code
      case Snakepit.execute("command", %{}) do
        {:ok, result} -> result
        {:error, %Snakepit.Error{category: :timeout}} -> retry()
        {:error, %Snakepit.Error{category: :python_error} = error} ->
          Logger.error("Python error: #{error.message}")
          Logger.debug("Traceback: #{error.python_traceback}")
        {:error, error} -> {:error, error}
      end
  """

  @type category :: :worker | :timeout | :python_error | :grpc_error | :validation | :pool

  @type t :: %__MODULE__{
    category: category(),
    message: String.t(),
    details: map(),
    python_traceback: String.t() | nil,
    grpc_status: atom() | nil
  }

  defstruct [:category, :message, :details, :python_traceback, :grpc_status]

  @doc """
  Creates a worker-related error.

  ## Examples

      iex> Snakepit.Error.worker_error("Worker crashed")
      %Snakepit.Error{category: :worker, message: "Worker crashed", details: %{}}

      iex> Snakepit.Error.worker_error("Worker not found", %{worker_id: "w1"})
      %Snakepit.Error{category: :worker, message: "Worker not found", details: %{worker_id: "w1"}}
  """
  @spec worker_error(String.t(), map()) :: t()
  def worker_error(message, details \\ %{}) do
    %__MODULE__{
      category: :worker,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a timeout error.

  ## Examples

      iex> Snakepit.Error.timeout_error("Request timed out", %{timeout_ms: 5000})
      %Snakepit.Error{category: :timeout, message: "Request timed out", details: %{timeout_ms: 5000}}
  """
  @spec timeout_error(String.t(), map()) :: t()
  def timeout_error(message, details \\ %{}) do
    %__MODULE__{
      category: :timeout,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a Python exception error with traceback.

  ## Examples

      iex> Snakepit.Error.python_error("ValueError", "Invalid input", "Traceback...")
      %Snakepit.Error{
        category: :python_error,
        message: "ValueError: Invalid input",
        python_traceback: "Traceback...",
        details: %{exception_type: "ValueError"}
      }
  """
  @spec python_error(String.t(), String.t(), String.t(), map()) :: t()
  def python_error(exception_type, message, traceback, details \\ %{}) do
    %__MODULE__{
      category: :python_error,
      message: "#{exception_type}: #{message}",
      details: Map.put(details, :exception_type, exception_type),
      python_traceback: traceback
    }
  end

  @doc """
  Creates a gRPC communication error.

  ## Examples

      iex> Snakepit.Error.grpc_error(:unavailable, "Service unavailable")
      %Snakepit.Error{
        category: :grpc_error,
        message: "Service unavailable",
        grpc_status: :unavailable
      }
  """
  @spec grpc_error(atom(), String.t(), map()) :: t()
  def grpc_error(status, message, details \\ %{}) do
    %__MODULE__{
      category: :grpc_error,
      message: message,
      grpc_status: status,
      details: details
    }
  end

  @doc """
  Creates a pool management error.

  ## Examples

      iex> Snakepit.Error.pool_error("Pool not found", %{pool_name: :test})
      %Snakepit.Error{category: :pool, message: "Pool not found", details: %{pool_name: :test}}
  """
  @spec pool_error(String.t(), map()) :: t()
  def pool_error(message, details \\ %{}) do
    %__MODULE__{
      category: :pool,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a validation error.

  ## Examples

      iex> Snakepit.Error.validation_error("Invalid field", %{field: "user_id"})
      %Snakepit.Error{category: :validation, message: "Invalid field", details: %{field: "user_id"}}
  """
  @spec validation_error(String.t(), map()) :: t()
  def validation_error(message, details \\ %{}) do
    %__MODULE__{
      category: :validation,
      message: message,
      details: details
    }
  end

  defimpl String.Chars do
    def to_string(%Snakepit.Error{} = error) do
      base = "[#{error.category}] #{error.message}"

      details_str = if map_size(error.details) > 0 do
        "\nDetails: #{inspect(error.details)}"
      else
        ""
      end

      traceback_str = if error.python_traceback do
        "\n\nPython Traceback:\n#{error.python_traceback}"
      else
        ""
      end

      grpc_str = if error.grpc_status do
        "\ngRPC Status: #{error.grpc_status}"
      else
        ""
      end

      base <> details_str <> grpc_str <> traceback_str
    end
  end
end
```

#### Step 2.3: Run Tests - Confirm Compilation

```bash
cd ~/p/g/n/snakepit
mix compile
```

Expected: Compiles successfully.

#### Step 2.4: Run Tests - Confirm Pass

```bash
cd ~/p/g/n/snakepit
mix test test/unit/error_test.exs
```

Expected: All tests pass.

#### Step 2.5: Update Pool to Use Structured Errors

Update `lib/snakepit/pool/pool.ex` (example changes):

```elixir
# Add alias at top
alias Snakepit.Error

# Replace:
{:error, :pool_not_found}
# With:
{:error, Error.pool_error("Pool not found", %{pool_name: pool_name})}

# Replace:
{:error, :timeout}
# With:
{:error, Error.timeout_error("Worker checkout timed out", %{timeout_ms: timeout})}

# Replace:
{:error, :streaming_not_supported_by_worker}
# With:
{:error, Error.worker_error("Streaming not supported by worker", %{worker_module: worker_module})}
```

#### Step 2.6: Update GRPCWorker to Use Structured Errors

Update `lib/snakepit/grpc_worker.ex` (example changes):

```elixir
# Add alias at top
alias Snakepit.Error

# Replace:
{:error, :worker_not_found}
# With:
{:error, Error.worker_error("Worker not found", %{worker_id: worker_id})}

# When catching gRPC errors, create structured error:
case GRPC.Stub.call(...) do
  {:ok, result} -> {:ok, result}
  {:error, %GRPC.RPCError{status: status, message: message}} ->
    {:error, Error.grpc_error(status, message, %{command: command})}
end
```

#### Step 2.7: Run All Tests - Verify No Breakage

```bash
cd ~/p/g/n/snakepit
mix test
```

Expected: All existing tests still pass (backward compatibility maintained).

### Phase 3: Complete Type Specifications

#### Step 3.1: Add Type Specs to Snakepit Module

Update `lib/snakepit.ex`:

```elixir
defmodule Snakepit do
  @moduledoc """
  Snakepit - A generalized high-performance pooler and session manager.

  ... existing docs ...
  """

  # Type definitions
  @type command :: String.t()
  @type args :: map()
  @type result :: term()
  @type session_id :: String.t()
  @type callback_fn :: (term() -> any())
  @type pool_name :: atom() | pid()

  @doc """
  Convenience function to execute commands on the pool.

  ## Examples

      {:ok, result} = Snakepit.execute("ping", %{test: true})

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 60000)
    * `:session_id` - Execute with session affinity
  """
  @spec execute(command(), args(), keyword()) :: {:ok, result()} | {:error, Snakepit.Error.t()}
  def execute(command, args, opts \\ []) do
    Snakepit.Pool.execute(command, args, opts)
  end

  @doc """
  Executes a command in session context with worker affinity.

  This function executes commands with session-based worker affinity,
  ensuring that subsequent calls with the same session_id prefer
  the same worker when possible for state continuity.
  """
  @spec execute_in_session(session_id(), command(), args(), keyword()) ::
    {:ok, result()} | {:error, Snakepit.Error.t()}
  def execute_in_session(session_id, command, args, opts \\ []) do
    # Add session_id to opts for session affinity
    opts_with_session = Keyword.put(opts, :session_id, session_id)

    # Execute command with session affinity (no args enhancement)
    execute(command, args, opts_with_session)
  end

  @doc """
  Get pool statistics.

  Returns aggregate stats across all pools or stats for a specific pool.
  """
  @spec get_stats(pool_name()) :: map()
  def get_stats(pool \\ Snakepit.Pool) do
    Snakepit.Pool.get_stats(pool)
  end

  @doc """
  List workers from the pool.

  Returns a list of worker IDs.
  """
  @spec list_workers(pool_name()) :: [String.t()]
  def list_workers(pool \\ Snakepit.Pool) do
    Snakepit.Pool.list_workers(pool)
  end

  @doc """
  Executes a streaming command with a callback function.

  ## Examples

      Snakepit.execute_stream("batch_inference", %{items: [...]}, fn chunk ->
        IO.puts("Received: \#{inspect(chunk)}")
      end)

  ## Options

    * `:pool` - The pool to use (default: `Snakepit.Pool`)
    * `:timeout` - Request timeout in ms (default: 300000)
    * `:session_id` - Run in a specific session

  ## Returns

  Returns `:ok` on success or `{:error, reason}` on failure.

  Note: Streaming is only supported with gRPC adapters.
  """
  @spec execute_stream(command(), args(), callback_fn(), keyword()) ::
    :ok | {:error, Snakepit.Error.t()}
  def execute_stream(command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, Snakepit.Error.validation_error("Streaming not supported by adapter", %{
        adapter: adapter
      })}
    else
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts)
    end
  end

  @doc """
  Executes a command in a session with a callback function.
  """
  @spec execute_in_session_stream(session_id(), command(), args(), callback_fn(), keyword()) ::
    :ok | {:error, Snakepit.Error.t()}
  def execute_in_session_stream(session_id, command, args \\ %{}, callback_fn, opts \\ []) do
    ensure_started!()

    adapter = Application.get_env(:snakepit, :adapter_module)

    unless function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      {:error, Snakepit.Error.validation_error("Streaming not supported by adapter", %{
        adapter: adapter
      })}
    else
      opts_with_session = Keyword.put(opts, :session_id, session_id)
      Snakepit.Pool.execute_stream(command, args, callback_fn, opts_with_session)
    end
  end

  # ... rest of module unchanged ...
end
```

#### Step 3.2: Run Dialyzer

```bash
cd ~/p/g/n/snakepit
mix dialyzer
```

Expected: No warnings.

#### Step 3.3: Verify All Tests Pass

```bash
cd ~/p/g/n/snakepit
mix test
```

Expected: All tests pass, no warnings.

## VERIFICATION CHECKLIST

### Python Side
- [ ] `orjson>=3.9.0` added to requirements.txt
- [ ] All `json.dumps()` calls replaced with orjson
- [ ] All `json.loads()` calls replaced with orjson
- [ ] Graceful fallback implemented
- [ ] Performance benchmarks show 5-6x speedup
- [ ] All existing serialization tests pass
- [ ] No warnings from pytest

### Elixir Side
- [ ] `lib/snakepit/error.ex` created with complete implementation
- [ ] All error helper functions implemented and tested
- [ ] `lib/snakepit.ex` has complete @type and @spec coverage
- [ ] `lib/snakepit/pool/pool.ex` updated to use structured errors
- [ ] `lib/snakepit/grpc_worker.ex` updated to use structured errors
- [ ] All tests pass: `mix test`
- [ ] No Dialyzer warnings: `mix dialyzer`
- [ ] No compiler warnings: `mix compile --warnings-as-errors`
- [ ] Documentation generated: `mix docs`

### Integration
- [ ] Existing integration tests pass
- [ ] Error messages are more informative
- [ ] Backward compatibility maintained
- [ ] No performance regressions

## SUCCESS CRITERIA

1. ✅ All Python tests pass: `cd priv/python && pytest -v`
2. ✅ All Elixir tests pass: `mix test`
3. ✅ No Dialyzer warnings: `mix dialyzer`
4. ✅ No compiler warnings: `mix compile --warnings-as-errors`
5. ✅ Benchmarks show 5-6x JSON speedup
6. ✅ Error messages include structured details
7. ✅ Documentation builds: `mix docs`
8. ✅ Code formatted: `mix format --check-formatted`

## DELIVERABLES

1. Updated `priv/python/requirements.txt` with orjson
2. Updated `priv/python/snakepit_bridge/serialization.py` with orjson integration
3. New `priv/python/tests/test_orjson_integration.py` with benchmarks
4. New `lib/snakepit/error.ex` with structured error type
5. New `test/unit/error_test.exs` with comprehensive error tests
6. Updated `lib/snakepit.ex` with complete @spec coverage
7. Updated error returns in Pool and GRPCWorker modules
8. Passing test suite
9. Passing Dialyzer checks

## ESTIMATED EFFORT

- Python orjson integration: 2-3 hours
- Elixir error struct: 3-4 hours
- Type specifications: 4-5 hours
- Testing and verification: 2-3 hours
- **Total: 11-15 hours (~2 days)**

## NOTES

- Maintain backward compatibility at all times
- Run tests after each phase
- Document any deviations from plan
- Benchmark performance before and after
- Keep commits atomic per phase

---

**Ready to implement? Start with Phase 1 (Python orjson integration), then Phase 2 (Error struct), then Phase 3 (Type specs). Follow TDD strictly: Test → Stub → Fail → Implement → Pass → Verify.**
