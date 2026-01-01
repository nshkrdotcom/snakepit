# Python Adapters

This guide covers creating Python adapters for Snakepit, including tool definition, session management, streaming, thread safety, and bidirectional communication with Elixir.

## Overview

Python adapters expose Python functionality to Elixir through Snakepit's gRPC bridge. An adapter is a Python class that:

- Inherits from `BaseAdapter` (or `ThreadSafeAdapter` for concurrent workloads)
- Defines tools using the `@tool` decorator
- Handles requests from Elixir and returns results
- Optionally calls back into Elixir tools

## Creating an Adapter

### BaseAdapter Inheritance

All Python adapters inherit from `BaseAdapter`:

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    """Custom adapter implementing Python tools."""

    def __init__(self):
        super().__init__()
        self.session_context = None

    def set_session_context(self, session_context):
        """Called by the framework to inject session context."""
        self.session_context = session_context
```

### The @tool Decorator

The `@tool` decorator marks methods as tools and attaches metadata for registration:

```python
class MyAdapter(BaseAdapter):

    @tool(description="Add two numbers together")
    def add(self, a: float, b: float) -> float:
        return a + b

    @tool(
        description="Search for items",
        supports_streaming=True,
        required_variables=["api_key"]
    )
    def search(self, query: str, limit: int = 10):
        return {"results": [], "query": query}
```

**Decorator Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `description` | `str` | Docstring | Human-readable description |
| `supports_streaming` | `bool` | `False` | Enable streaming responses |
| `required_variables` | `List[str]` | `[]` | Required environment/session variables |

### Parameter Types and Serialization

Snakepit infers parameter types from Python type annotations:

| Python Type | Protobuf Type | Notes |
|-------------|---------------|-------|
| `str` | `string` | UTF-8 encoded |
| `int` | `integer` | 64-bit integers |
| `float` | `float` | Double precision |
| `bool` | `boolean` | True/False |
| `list` | `embedding` | Lists of floats |
| `dict` | `map` | Nested structures |
| `np.ndarray` | `tensor` | Shape preserved |
| `bytes` | `binary` | Raw binary data |

### Per-Request Lifecycle

Adapters follow a **per-request lifecycle**:

1. A new adapter instance is created for each incoming RPC request
2. `initialize()` is called (if defined) at the start of each request
3. The tool is executed via `execute_tool()` or a decorated method
4. `cleanup()` is called (if defined) at the end of each request, even on error

Both `initialize()` and `cleanup()` can be sync or async.

```python
# Module-level cache for expensive resources
_model_cache = {}

class MLAdapter(BaseAdapter):

    def __init__(self):
        super().__init__()
        self.model = None

    def initialize(self):
        """Called at the start of each request."""
        # Cache expensive resources at module level
        if "model" not in _model_cache:
            _model_cache["model"] = load_model("my-model")
        self.model = _model_cache["model"]

    def cleanup(self):
        """Called at the end of each request (even on error)."""
        # Release request-specific resources here
        pass
```

**Important**: Since adapters are instantiated per-request, do NOT rely on instance state
persisting across requests. Use module-level caches (as shown above) or external stores
for state that must survive across requests.

## Session Context

### Accessing session_id

```python
@tool(description="Get session info")
def get_session_info(self) -> dict:
    return {
        "session_id": self.session_context.session_id,
        "metadata": self.session_context.request_metadata
    }
```

### call_elixir_tool() for Cross-Language Calls

```python
@tool(description="Call an Elixir tool")
def call_backend_tool(self, operation: str, data: dict) -> dict:
    if operation not in self.session_context.elixir_tools:
        raise ValueError(f"Tool '{operation}' not found")

    return self.session_context.call_elixir_tool(
        operation,
        input=data,
        options={"timeout": 5000}
    )
```

### elixir_tools Proxy

The session context lazily loads available Elixir tools:

```python
available_tools = self.session_context.elixir_tools
# Returns: {"validate_data": {"name": "validate_data", "parameters": {...}}, ...}
```

## Streaming Tools

### Enabling Streaming

Mark a tool as streaming-capable with `supports_streaming=True`:

```python
@tool(description="Stream data chunks", supports_streaming=True)
def stream_data(self, count: int = 5):
    for i in range(count):
        yield StreamChunk(
            data={"index": i + 1, "total": count},
            is_final=(i == count - 1)
        )
        time.sleep(0.5)
```

### Streaming Patterns

**Progress Updates:**

```python
@tool(description="Long operation", supports_streaming=True)
def long_operation(self, steps: int = 10):
    for i in range(steps):
        yield StreamChunk({
            "progress": (i + 1) / steps * 100,
            "status": "processing"
        }, is_final=False)

    yield StreamChunk({"status": "complete"}, is_final=True)
```

**Large Dataset Generation:**

```python
@tool(description="Generate dataset", supports_streaming=True)
def generate_dataset(self, rows: int = 1000, chunk_size: int = 100):
    total_sent = 0
    while total_sent < rows:
        batch = min(chunk_size, rows - total_sent)
        total_sent += batch
        yield StreamChunk({
            "data": np.random.randn(batch, 10).tolist()
        }, is_final=(total_sent >= rows))
```

## Thread-Safe Adapters (Python 3.13+)

### ThreadSafeAdapter Class

For concurrent request handling in multi-threaded environments:

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method

class ConcurrentMLAdapter(ThreadSafeAdapter):
    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        self.model = load_model("shared-model")  # Shared read-only
        self.request_log = []  # Shared mutable: requires locking
```

### The @thread_safe_method Decorator

```python
@thread_safe_method
@tool(description="Make a prediction")
def predict(self, input_data: str) -> dict:
    # Pattern 1: Read shared config (no lock needed)
    model_name = self.config["model_name"]

    # Pattern 2: Thread-local cache
    cache = self.get_thread_local('cache', {})
    if input_data in cache:
        return cache[input_data]

    result = self.model.predict(input_data)
    cache[input_data] = result
    self.set_thread_local('cache', cache)

    # Pattern 3: Write to shared state (MUST use lock)
    with self.acquire_lock():
        self.request_log.append(result)

    return result
```

### Thread-Local Storage

```python
cache = self.get_thread_local('my_cache', {})  # Get with default
self.set_thread_local('my_cache', updated)     # Set value
self.clear_thread_local('my_cache')            # Clear specific key
self.clear_thread_local()                      # Clear all
```

### acquire_lock() for Shared State

```python
with self.acquire_lock():
    self.shared_counter += 1
    self.shared_list.append(item)
```

## Bidirectional Tool Bridge

### Registering Elixir Tools

On the Elixir side, register tools with `exposed_to_python: true`:

```elixir
alias Snakepit.Bridge.ToolRegistry

ToolRegistry.register_elixir_tool(
  session_id,
  "validate_schema",
  &MyModule.validate_schema/1,
  %{
    description: "Validate data against schema",
    exposed_to_python: true,
    parameters: [%{name: "data", type: "map", required: true}]
  }
)
```

### Python Calling Elixir Tools

```python
@tool(description="Process with validation")
def process_with_validation(self, data: dict) -> dict:
    validation = self.session_context.call_elixir_tool(
        "validate_schema",
        data=data,
        schema_name="user_input"
    )

    if not validation.get("valid"):
        return {"error": "Validation failed", "details": validation.get("errors")}

    return {"success": True, "result": self.process_data(data)}
```

### Complete Workflow Example

```python
class MLPipelineAdapter(BaseAdapter):
    @tool(description="Run ML pipeline")
    def run_pipeline(self, input_data: dict) -> dict:
        # 1. Validate via Elixir
        validation = self.session_context.call_elixir_tool("validate_input", data=input_data)
        if not validation["valid"]:
            return {"error": "Invalid input"}

        # 2. ML inference (Python)
        predictions = self.model.predict(input_data["features"])

        # 3. Store via Elixir
        storage = self.session_context.call_elixir_tool(
            "store_predictions",
            predictions=predictions.tolist()
        )

        return {"success": True, "prediction_id": storage["id"]}
```

## Complete Adapter Example

```python
from typing import Dict, Any
import time
import numpy as np
from snakepit_bridge.base_adapter import BaseAdapter, tool
from snakepit_bridge import telemetry

# Module-level cache for expensive resources
_model = None

class ExampleAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        self.session_context = None
        self.model = None

    def set_session_context(self, ctx):
        self.session_context = ctx

    def initialize(self):
        """Per-request initialization - load from cache."""
        global _model
        if _model is None:
            _model = self.load_model()
        self.model = _model

    def cleanup(self):
        """Per-request cleanup - release request-specific resources."""
        pass  # Model stays cached at module level

    @tool(description="Echo input")
    def echo(self, message: str) -> str:
        return f"Echo: {message}"

    @tool(description="Add two numbers")
    def add(self, a: float, b: float) -> float:
        return a + b

    @tool(description="ML prediction")
    def predict(self, input_data: Dict[str, Any]) -> Dict[str, Any]:
        with telemetry.span("prediction", {"input_size": len(str(input_data))}):
            features = np.array(input_data.get("features", []))
            prediction = self.model.predict(features)
            return {"prediction": prediction.tolist()}

    @tool(description="Stream progress", supports_streaming=True)
    def process_with_progress(self, items: int = 10):
        for i in range(items):
            time.sleep(0.1)
            yield {"data": {"item": i + 1, "progress": (i + 1) / items * 100},
                   "is_final": (i == items - 1)}

    @tool(description="Validate and process")
    def validate_and_process(self, data: Dict[str, Any]) -> Dict[str, Any]:
        validation = self.session_context.call_elixir_tool("validate", data=data)
        if not validation.get("valid"):
            return {"error": "Validation failed"}
        result = self.process_data(data)
        self.session_context.call_elixir_tool("store_result", result=result)
        return {"success": True, "result": result}
```

## Generating Adapter Scaffolding

```bash
mix snakepit.gen.adapter my_adapter
```

Creates `priv/python/my_adapter/` with `adapter.py` and handler directories.

Configure in your pool:

```elixir
adapter_args: ["--adapter", "my_adapter.adapter.MyAdapter"]
```
