# Python Bridge, Adapters, and Streaming

This document provides comprehensive documentation for the Python side of the Snakepit bridge, covering adapter creation, thread safety, session management, streaming tools, bidirectional communication, and telemetry.

## Table of Contents

1. [Creating Python Adapters](#1-creating-python-adapters)
2. [Thread-Safe Adapters (Python 3.13+)](#2-thread-safe-adapters-python-313)
3. [Session Context](#3-session-context)
4. [Streaming Tools](#4-streaming-tools)
5. [Bidirectional Tool Bridge](#5-bidirectional-tool-bridge)
6. [Python Telemetry](#6-python-telemetry)
7. [Working Examples](#7-working-examples)

---

## 1. Creating Python Adapters

Python adapters are the primary mechanism for exposing Python functionality to Elixir through Snakepit's gRPC bridge.

### 1.1 BaseAdapter Class

All Python adapters inherit from `BaseAdapter`, which provides tool discovery, registration, and execution infrastructure.

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):
    """Custom adapter implementing Python tools."""

    def __init__(self):
        super().__init__()
        # Initialize any shared resources
        self.session_context = None

    def set_session_context(self, session_context):
        """Called by the framework to inject session context."""
        self.session_context = session_context
```

**Key Features:**
- Automatic tool discovery via introspection
- Caching of tool registrations for performance
- Support for both decorated methods and legacy `execute_tool` pattern

### 1.2 The @tool Decorator

The `@tool` decorator marks methods as tools and attaches metadata for registration.

```python
from snakepit_bridge.base_adapter import BaseAdapter, tool

class MyAdapter(BaseAdapter):

    @tool(description="Add two numbers together")
    def add(self, a: float, b: float) -> float:
        """Add two numbers and return the result."""
        return a + b

    @tool(
        description="Search for items with optional streaming",
        supports_streaming=True,
        required_variables=["api_key"]
    )
    def search(self, query: str, limit: int = 10):
        """Search for items matching the query."""
        return {"results": [], "query": query, "limit": limit}
```

**Decorator Options:**

| Option | Type | Description |
|--------|------|-------------|
| `description` | `str` | Human-readable description of the tool. Falls back to docstring if empty. |
| `supports_streaming` | `bool` | Whether the tool can return streaming responses. Default: `False`. |
| `required_variables` | `List[str]` | Environment variables or session variables required by the tool. |

### 1.3 Parameter Types and Serialization

Snakepit automatically infers parameter types from Python type annotations and handles serialization via the `TypeSerializer` class.

**Supported Types:**

| Python Type | Protobuf Type | Notes |
|-------------|---------------|-------|
| `str` | `string` | UTF-8 encoded strings |
| `int` | `integer` | 64-bit integers |
| `float` | `float` | Double precision floats |
| `bool` | `boolean` | True/False values |
| `list` | `embedding` | Lists of floats for ML embeddings |
| `dict` | `map` | Nested structures |
| `np.ndarray` | `tensor` | NumPy arrays with shape preservation |
| `bytes` | `binary` | Raw binary data |

**Serialization Features:**

- **JSON serialization** with optional `orjson` for 6x performance boost
- **Binary serialization** for large tensors (>10KB) using pickle
- **Special float handling** for `NaN`, `Infinity`, `-Infinity`
- **Zero-copy references** for efficient large data transfer

```python
from snakepit_bridge.serialization import TypeSerializer

# Encoding a value
any_msg, binary_data = TypeSerializer.encode_any(value, "tensor")

# Decoding a value
decoded = TypeSerializer.decode_any(any_msg, binary_data)

# Constraint validation
TypeSerializer.validate_constraints(value, "float", {"min": 0.0, "max": 1.0})
```

### 1.4 Initialize and Cleanup Methods

Adapters can define lifecycle methods for resource management.

```python
class MLAdapter(BaseAdapter):

    def __init__(self):
        super().__init__()
        self.model = None

    async def initialize(self):
        """Called before first tool execution. Load expensive resources here."""
        self.model = await load_model("my-model")

    def cleanup(self):
        """Called during session cleanup. Release resources here."""
        if self.model:
            self.model.unload()
            self.model = None
```

**Note:** The `initialize` method can be either sync or async. The framework detects and handles both patterns.

---

## 2. Thread-Safe Adapters (Python 3.13+)

For concurrent request handling in multi-threaded environments, Snakepit provides the `ThreadSafeAdapter` base class.

### 2.1 ThreadSafeAdapter Class

```python
from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method

class ConcurrentMLAdapter(ThreadSafeAdapter):
    """Adapter that handles concurrent requests safely."""

    __thread_safe__ = True  # Required marker

    def __init__(self):
        super().__init__()
        # Shared read-only: loaded once, read by all threads
        self.model = load_model("shared-model")

        # Shared mutable: requires locking
        self.request_log = []
        self.total_predictions = 0
```

**Thread Safety Patterns:**

1. **Shared Read-Only** - Resources loaded at initialization, never modified
2. **Thread-Local** - Per-thread isolated state using `get_thread_local()`
3. **Locked Writes** - Shared mutable state protected by `acquire_lock()`

### 2.2 The @thread_safe_method Decorator

```python
@thread_safe_method
@tool(description="Make a prediction")
def predict(self, input_data: str) -> dict:
    """Thread-safe prediction method."""

    # Pattern 1: Read shared config (no lock needed)
    model_name = self.config["model_name"]

    # Pattern 2: Thread-local cache
    cache = self.get_thread_local('predictions_cache', {})
    if input_data in cache:
        return cache[input_data]

    # Perform prediction
    result = self.model.predict(input_data)

    # Update thread-local cache
    cache[input_data] = result
    self.set_thread_local('predictions_cache', cache)

    # Pattern 3: Write to shared state (MUST use lock)
    with self.acquire_lock():
        self.request_log.append(result)
        self.total_predictions += 1

    return result
```

**Decorator Features:**
- Automatic request tracking per thread
- Execution timing and logging
- Exception handling with thread context

### 2.3 Thread-Local Storage

```python
# Get thread-local value (returns default if not set)
cache = self.get_thread_local('my_cache', {})

# Set thread-local value
self.set_thread_local('my_cache', updated_cache)

# Clear specific key
self.clear_thread_local('my_cache')

# Clear all thread-local values
self.clear_thread_local()
```

### 2.4 Acquiring Locks for Shared State

```python
# Context manager for critical sections
with self.acquire_lock():
    # This code is serialized across all threads
    self.shared_counter += 1
    self.shared_list.append(item)

# Get adapter statistics
stats = self.get_stats()
# Returns: {
#   "adapter_class": "MyAdapter",
#   "thread_safe": True,
#   "tracker": {"total_requests": 42, "active_threads": 3, ...}
# }
```

---

## 3. Session Context

The `SessionContext` provides access to session information and enables calling Elixir tools from Python.

### 3.1 Accessing session_id

```python
class MyAdapter(BaseAdapter):

    @tool(description="Get current session info")
    def get_session_info(self) -> dict:
        """Return information about the current session."""
        return {
            "session_id": self.session_context.session_id,
            "metadata": self.session_context.request_metadata
        }
```

### 3.2 The call_elixir_tool() Method

Python adapters can call Elixir-implemented tools through the session context.

```python
@tool(description="Call an Elixir tool")
def call_backend_tool(self, operation: str, data: dict) -> dict:
    """Execute an operation using an Elixir tool."""

    # Check if the tool is available
    if operation not in self.session_context.elixir_tools:
        available = list(self.session_context.elixir_tools.keys())
        raise ValueError(f"Tool '{operation}' not found. Available: {available}")

    # Call the Elixir tool
    result = self.session_context.call_elixir_tool(
        operation,
        input=data,
        options={"timeout": 5000}
    )

    return result
```

### 3.3 Elixir Tool Proxy

The session context lazily loads available Elixir tools via gRPC.

```python
# Access the elixir_tools property (lazy-loaded)
available_tools = self.session_context.elixir_tools

# Returns dict of tool_name -> tool_spec:
# {
#   "validate_data": {
#     "name": "validate_data",
#     "description": "Validate input data against schema",
#     "parameters": {...}
#   },
#   ...
# }
```

**Context Manager Support:**

```python
# SessionContext can be used as a context manager
with SessionContext(stub, session_id) as ctx:
    result = ctx.call_elixir_tool("process", data=input_data)
# Cleanup is automatic
```

---

## 4. Streaming Tools

Streaming tools enable sending incremental results back to Elixir.

### 4.1 Enabling Streaming

Mark a tool as streaming-capable with `supports_streaming=True`:

```python
@tool(description="Stream data chunks", supports_streaming=True)
def stream_data(self, count: int = 5, delay: float = 1.0):
    """Stream count data chunks with optional delay."""
    for i in range(count):
        yield StreamChunk(
            data={
                "index": i + 1,
                "total": count,
                "message": f"Chunk {i + 1}/{count}"
            },
            is_final=(i == count - 1)
        )
        if i < count - 1:
            time.sleep(delay)
```

### 4.2 The StreamChunk Class

```python
from snakepit_bridge.adapters.showcase.tool import StreamChunk

class StreamChunk:
    """Wrapper for streaming data chunks."""

    def __init__(self, data, is_final=False):
        """
        Args:
            data: The chunk payload (dict, str, bytes, etc.)
            is_final: Whether this is the last chunk
        """
        self.data = data
        self.is_final = is_final
```

### 4.3 Streaming Patterns

**Progress Updates:**

```python
@tool(description="Long operation with progress", supports_streaming=True)
def long_operation(self, steps: int = 10):
    """Execute a long operation with progress updates."""
    for i in range(steps):
        # Do work...
        yield StreamChunk({
            "step": i + 1,
            "total": steps,
            "progress": (i + 1) / steps * 100,
            "status": "processing"
        }, is_final=False)

    # Final result
    yield StreamChunk({
        "status": "complete",
        "result": "Operation finished successfully"
    }, is_final=True)
```

**Large Dataset Generation:**

```python
@tool(description="Generate large dataset", supports_streaming=True)
def generate_dataset(self, rows: int = 1000, chunk_size: int = 100):
    """Generate and stream a large dataset in chunks."""
    total_sent = 0

    while total_sent < rows:
        rows_in_chunk = min(chunk_size, rows - total_sent)
        total_sent += rows_in_chunk

        # Generate chunk data
        data = np.random.randn(rows_in_chunk, 10)

        yield StreamChunk({
            "rows_in_chunk": rows_in_chunk,
            "total_rows": total_sent,
            "data": data.tolist()
        }, is_final=(total_sent >= rows))
```

**Infinite Streams (for real-time data):**

```python
@tool(description="Real-time data stream", supports_streaming=True)
def realtime_stream(self, interval_ms: int = 500):
    """Stream real-time data until cancelled."""
    counter = 0
    while True:  # Framework handles cancellation
        counter += 1
        yield StreamChunk({
            "sequence": counter,
            "timestamp": datetime.now().isoformat(),
            "data": get_realtime_data()
        }, is_final=False)
        time.sleep(interval_ms / 1000.0)
```

---

## 5. Bidirectional Tool Bridge

Snakepit enables true bidirectional communication where Python can call Elixir tools and vice versa.

### 5.1 Registering Elixir Tools

On the Elixir side, register tools with `exposed_to_python: true`:

```elixir
# In your Elixir code
alias Snakepit.Bridge.ToolRegistry

# Register a tool that Python can call
ToolRegistry.register_elixir_tool(
  session_id,
  "validate_schema",
  &MyModule.validate_schema/1,
  %{
    description: "Validate data against a JSON schema",
    exposed_to_python: true,
    parameters: [
      %{name: "data", type: "map", required: true},
      %{name: "schema_name", type: "string", required: true}
    ]
  }
)
```

**ToolRegistry API:**

```elixir
# Register an Elixir tool
ToolRegistry.register_elixir_tool(session_id, tool_name, handler_fn, metadata)

# Register a Python tool (called by framework)
ToolRegistry.register_python_tool(session_id, tool_name, worker_id, metadata)

# Get a specific tool
{:ok, tool_spec} = ToolRegistry.get_tool(session_id, tool_name)

# List all tools for a session
tools = ToolRegistry.list_tools(session_id)

# List only Elixir tools exposed to Python
exposed = ToolRegistry.list_exposed_elixir_tools(session_id)

# Execute a local Elixir tool
{:ok, result} = ToolRegistry.execute_local_tool(session_id, tool_name, params)

# Cleanup session tools
ToolRegistry.cleanup_session(session_id)
```

### 5.2 Python Calling Elixir Tools

```python
class IntegrationAdapter(BaseAdapter):

    @tool(description="Process data using Elixir validation")
    def process_with_validation(self, data: dict) -> dict:
        """Process data after validating with Elixir."""

        # Call Elixir validation tool
        validation_result = self.session_context.call_elixir_tool(
            "validate_schema",
            data=data,
            schema_name="user_input"
        )

        if not validation_result.get("valid"):
            return {
                "error": "Validation failed",
                "details": validation_result.get("errors")
            }

        # Continue with processing
        processed = self.process_data(data)

        return {
            "success": True,
            "result": processed
        }
```

### 5.3 Complete Workflow Example

```python
class MLPipelineAdapter(BaseAdapter):
    """Adapter demonstrating full bidirectional workflow."""

    @tool(description="Run ML pipeline with Elixir orchestration")
    def run_pipeline(self, input_data: dict) -> dict:
        """
        Complete workflow:
        1. Python receives request from Elixir
        2. Python calls Elixir for data validation
        3. Python performs ML inference
        4. Python calls Elixir to store results
        5. Python returns final result to Elixir
        """

        # Step 1: Validate input using Elixir tool
        validation = self.session_context.call_elixir_tool(
            "validate_input",
            data=input_data
        )

        if not validation["valid"]:
            return {"error": "Invalid input", "details": validation["errors"]}

        # Step 2: Perform ML inference (Python-side)
        predictions = self.model.predict(input_data["features"])

        # Step 3: Store results using Elixir tool
        storage_result = self.session_context.call_elixir_tool(
            "store_predictions",
            session_id=self.session_context.session_id,
            predictions=predictions.tolist(),
            metadata={"model_version": "1.0"}
        )

        # Step 4: Return combined result
        return {
            "success": True,
            "prediction_id": storage_result["id"],
            "predictions": predictions.tolist(),
            "storage_location": storage_result["path"]
        }
```

---

## 6. Python Telemetry

Snakepit provides a comprehensive telemetry system for monitoring Python adapter execution.

### 6.1 Emitting Events with telemetry.emit()

```python
from snakepit_bridge import telemetry

# Emit a simple event
telemetry.emit(
    "tool.execution.start",
    {"system_time": time.time_ns()},
    {"tool": "predict", "model": "gpt-4"},
    correlation_id="abc-123"
)

# Emit with measurements
telemetry.emit(
    "tool.execution.stop",
    {
        "duration": 1234,      # nanoseconds
        "bytes": 5000,         # result size
        "tokens": 150          # tokens processed
    },
    {
        "tool": "predict",
        "model": "gpt-4",
        "status": "success"
    },
    correlation_id="abc-123"
)
```

**Event Name Convention:**

Events use dotted notation: `category.subcategory.event`

Examples:
- `tool.execution.start`
- `tool.execution.stop`
- `tool.execution.exception`
- `model.inference.start`
- `cache.hit`
- `cache.miss`

### 6.2 Span Context with telemetry.span()

The `span()` context manager automatically emits start/stop/exception events:

```python
from snakepit_bridge import telemetry

@tool(description="Perform inference")
def inference(self, input_data: str) -> dict:
    correlation_id = telemetry.new_correlation_id()

    with telemetry.span("inference", {"model": "gpt-4"}, correlation_id):
        # Automatically emits: inference.start

        result = self.model.predict(input_data)

        # Automatically emits: inference.stop (with duration)
        # Or inference.exception (if exception raised)

    return result
```

**Nested Spans:**

```python
def complex_operation(self, data):
    with telemetry.span("complex_operation", {"size": len(data)}):

        with telemetry.span("preprocessing"):
            processed = self.preprocess(data)

        with telemetry.span("inference"):
            predictions = self.model.predict(processed)

        with telemetry.span("postprocessing"):
            result = self.postprocess(predictions)

    return result
```

### 6.3 Correlation IDs

Correlation IDs enable distributed tracing across Python and Elixir.

```python
from snakepit_bridge import telemetry

# Generate a new correlation ID
correlation_id = telemetry.new_correlation_id()

# Set correlation ID for current context
telemetry.set_correlation_id(correlation_id)

# Get current correlation ID
current_id = telemetry.get_correlation_id()

# Reset correlation ID
telemetry.reset_correlation_id()

# Include in outgoing gRPC metadata
metadata = telemetry.outgoing_metadata()
```

**Correlation ID Header:**

```python
from snakepit_bridge.telemetry import CORRELATION_HEADER

# Header name: "x-correlation-id"
# Automatically propagated in gRPC calls
```

### 6.4 Telemetry Backends

Snakepit supports pluggable telemetry backends:

```python
from snakepit_bridge import telemetry
from snakepit_bridge.telemetry.backends.grpc import GrpcBackend
from snakepit_bridge.telemetry.stream import TelemetryStream

# Set up gRPC backend (default for workers)
stream = TelemetryStream(max_buffer=1024)
telemetry.set_backend(GrpcBackend(stream))

# Check if telemetry is enabled
if telemetry.is_enabled():
    telemetry.emit("custom.event", {"value": 42})

# Get current backend
backend = telemetry.get_backend()

# Disable telemetry
telemetry.set_backend(None)
```

**Telemetry Control (from Elixir):**

The telemetry stream supports runtime control from Elixir:

- **Toggle:** Enable/disable telemetry
- **Sampling:** Set sampling rate (0.0 to 1.0)
- **Filtering:** Allow/deny patterns for events

---

## 7. Working Examples

### 7.1 Complete Adapter Example

```python
"""Complete example adapter demonstrating all features."""

from typing import Dict, Any
import time
import numpy as np

from snakepit_bridge.base_adapter import BaseAdapter, tool
from snakepit_bridge import telemetry


class ExampleAdapter(BaseAdapter):
    """Example adapter showcasing Snakepit features."""

    def __init__(self):
        super().__init__()
        self.session_context = None
        self.model = None

    def set_session_context(self, session_context):
        """Inject session context."""
        self.session_context = session_context

    async def initialize(self):
        """Load resources on first use."""
        self.model = await self.load_model()

    # Basic tool
    @tool(description="Echo input back")
    def echo(self, message: str) -> str:
        """Simple echo tool."""
        return f"Echo: {message}"

    # Tool with type inference
    @tool(description="Add two numbers")
    def add(self, a: float, b: float) -> float:
        """Add two numbers together."""
        return a + b

    # Tool with telemetry
    @tool(description="Perform ML prediction")
    def predict(self, input_data: Dict[str, Any]) -> Dict[str, Any]:
        """Run prediction with telemetry."""
        correlation_id = telemetry.get_correlation_id()

        with telemetry.span("prediction", {"input_size": len(str(input_data))}, correlation_id):
            features = np.array(input_data.get("features", []))
            prediction = self.model.predict(features)

            telemetry.emit(
                "prediction.result",
                {"confidence": float(prediction.max())},
                {"model": "example-model"},
                correlation_id
            )

            return {
                "prediction": prediction.tolist(),
                "confidence": float(prediction.max())
            }

    # Streaming tool
    @tool(description="Stream progress updates", supports_streaming=True)
    def process_with_progress(self, items: int = 10):
        """Process items with streaming progress."""
        for i in range(items):
            time.sleep(0.1)  # Simulate work

            yield {
                "data": {
                    "item": i + 1,
                    "total": items,
                    "progress": (i + 1) / items * 100
                },
                "is_final": (i == items - 1)
            }

    # Tool calling Elixir
    @tool(description="Validate and process data")
    def validate_and_process(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Validate data using Elixir, then process."""

        # Call Elixir validation
        validation = self.session_context.call_elixir_tool(
            "validate",
            data=data
        )

        if not validation.get("valid"):
            return {"error": "Validation failed", "details": validation}

        # Process the validated data
        result = self.process_data(data)

        # Store via Elixir
        self.session_context.call_elixir_tool(
            "store_result",
            result=result
        )

        return {"success": True, "result": result}
```

### 7.2 Thread-Safe Adapter Example

```python
"""Thread-safe adapter for concurrent requests."""

import threading
import time

from snakepit_bridge.base_adapter_threaded import ThreadSafeAdapter, thread_safe_method
from snakepit_bridge.base_adapter import tool


class ConcurrentAdapter(ThreadSafeAdapter):
    """Adapter handling concurrent requests safely."""

    __thread_safe__ = True

    def __init__(self):
        super().__init__()
        # Shared read-only resources
        self.config = {"model": "concurrent-model", "version": "1.0"}

        # Shared mutable state (requires locking)
        self.request_count = 0
        self.results_cache = {}

    @thread_safe_method
    @tool(description="Process request concurrently")
    def process(self, data: str) -> dict:
        """Thread-safe request processing."""
        thread_name = threading.current_thread().name

        # Check thread-local cache first
        cache = self.get_thread_local('local_cache', {})
        if data in cache:
            return cache[data]

        # Do processing
        result = {
            "input": data,
            "output": f"processed_{data}",
            "thread": thread_name,
            "model": self.config["model"]  # Safe: read-only
        }

        # Update thread-local cache
        cache[data] = result
        self.set_thread_local('local_cache', cache)

        # Update shared state (with lock)
        with self.acquire_lock():
            self.request_count += 1
            self.results_cache[data] = result

        return result

    @thread_safe_method
    @tool(description="Get processing statistics")
    def get_stats(self) -> dict:
        """Get thread-safe statistics."""
        with self.acquire_lock():
            return {
                "request_count": self.request_count,
                "cache_size": len(self.results_cache),
                **super().get_stats()
            }
```

### 7.3 Streaming Tool Example

```python
"""Streaming tool examples."""

import time
from typing import Generator, Dict, Any

from snakepit_bridge.base_adapter import BaseAdapter, tool


class StreamingAdapter(BaseAdapter):
    """Adapter with streaming capabilities."""

    @tool(description="Stream file processing progress", supports_streaming=True)
    def process_large_file(self, file_path: str, chunk_size: int = 1024):
        """Process a large file with streaming progress."""
        # Simulate file processing
        total_chunks = 100

        for i in range(total_chunks):
            # Simulate chunk processing
            time.sleep(0.05)

            yield {
                "data": {
                    "chunk": i + 1,
                    "total": total_chunks,
                    "progress_percent": (i + 1) / total_chunks * 100,
                    "bytes_processed": (i + 1) * chunk_size
                },
                "is_final": (i == total_chunks - 1),
                "metadata": {
                    "file": file_path
                }
            }

    @tool(description="Stream ML training progress", supports_streaming=True)
    def train_model(self, epochs: int = 10, batch_size: int = 32):
        """Train a model with streaming progress updates."""
        for epoch in range(epochs):
            # Simulate training
            time.sleep(0.2)

            loss = 1.0 / (epoch + 1)  # Simulated decreasing loss
            accuracy = min(0.9, 0.5 + epoch * 0.05)  # Simulated increasing accuracy

            yield {
                "data": {
                    "epoch": epoch + 1,
                    "total_epochs": epochs,
                    "loss": loss,
                    "accuracy": accuracy,
                    "status": "training"
                },
                "is_final": False
            }

        # Final result
        yield {
            "data": {
                "status": "complete",
                "final_loss": loss,
                "final_accuracy": accuracy,
                "model_path": "/models/trained_model.pkl"
            },
            "is_final": True
        }
```

### 7.4 Telemetry Integration Example

```python
"""Telemetry integration patterns."""

import time
from snakepit_bridge.base_adapter import BaseAdapter, tool
from snakepit_bridge import telemetry


class TelemetryAdapter(BaseAdapter):
    """Adapter demonstrating telemetry best practices."""

    @tool(description="Operation with full telemetry")
    def monitored_operation(self, input_data: dict) -> dict:
        """Fully monitored operation with telemetry."""

        # Get or create correlation ID
        correlation_id = telemetry.get_correlation_id() or telemetry.new_correlation_id()

        # Outer span for entire operation
        with telemetry.span("monitored_operation", {"input_keys": list(input_data.keys())}, correlation_id):

            # Preprocessing span
            with telemetry.span("preprocessing", correlation_id=correlation_id):
                preprocessed = self.preprocess(input_data)
                telemetry.emit(
                    "preprocessing.complete",
                    {"items_processed": len(preprocessed)},
                    correlation_id=correlation_id
                )

            # Main processing with custom events
            start_time = time.time_ns()
            result = self.process(preprocessed)

            telemetry.emit(
                "processing.complete",
                {
                    "duration_ns": time.time_ns() - start_time,
                    "result_size": len(str(result))
                },
                {"status": "success"},
                correlation_id
            )

            # Postprocessing span
            with telemetry.span("postprocessing", correlation_id=correlation_id):
                final_result = self.postprocess(result)

            return final_result

    def preprocess(self, data):
        return data

    def process(self, data):
        return {"processed": data}

    def postprocess(self, data):
        return data
```

---

## Summary

The Python bridge in Snakepit provides:

1. **BaseAdapter** - Foundation for all Python tools with automatic discovery and registration
2. **@tool decorator** - Mark methods as tools with metadata for Elixir integration
3. **ThreadSafeAdapter** - Concurrent request handling with thread-local storage and locking
4. **SessionContext** - Access to session state and bidirectional Elixir tool calls
5. **Streaming** - Incremental results via generator functions with `supports_streaming=True`
6. **Telemetry** - Comprehensive monitoring with emit(), span(), and correlation IDs

These components work together to enable seamless Python-Elixir integration for ML workloads, data processing pipelines, and any Python functionality that needs to be exposed to an Elixir application.
