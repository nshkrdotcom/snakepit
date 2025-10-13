# Snakepit Generic Python Adapter System
## Technical Requirements & Design Specification

**Version:** 1.0
**Date:** October 12, 2025
**Status:** Design Phase
**Target:** Snakepit v0.7.0
**Destination:** `~/p/g/n/snakepit/docs/20251012/generic_python_adapter_design.md`

---

## Executive Summary

**Problem:** Currently, integrating a new Python library into Snakepit requires:
1. Writing a custom Python adapter class
2. Manually defining gRPC service methods
3. Creating Elixir adapter module
4. Mapping functions and types manually

**Solution:** Generic Python adapter system that allows dropping in any Python library with zero code:
- Auto-discovery of Python module functions
- Automatic gRPC stub generation
- Type introspection and mapping
- Configuration-driven library loading

**Impact:**
- **Docling:** Parse complex PDFs, documents → RAG pipelines
- **Any Python ML library:** Just add to config and use
- **Rapid prototyping:** Test libraries in minutes, not hours

---

## Core Concept

```elixir
# Just configure it
config :snakepit,
  python_libraries: [
    %{
      name: "docling",
      module: "docling.document_converter",
      pip_package: "docling"
    },
    %{
      name: "pandas",
      module: "pandas",
      pip_package: "pandas"
    }
  ]

# And use it immediately
{:ok, result} = Snakepit.execute("python.docling.parse_pdf", %{
  file_path: "/path/to/doc.pdf"
})

{:ok, df_info} = Snakepit.execute("python.pandas.read_csv", %{
  filepath: "/data/file.csv"
})
```

**Zero custom adapter code required.**

---

## Architecture Overview

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Elixir Side (Snakepit)                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         Snakepit.Adapters.PythonGeneric                │ │
│  │                                                        │ │
│  │  • Reads python_libraries config                      │ │
│  │  • Sends library specs to Python                      │ │
│  │  • Routes commands: "python.{lib}.{func}"             │ │
│  │  • Type coercion (Elixir <-> Python)                  │ │
│  └─────────────────────┬──────────────────────────────────┘ │
│                        │ gRPC                               │
└────────────────────────┼────────────────────────────────────┘
                         │
                    ┌────▼────────────────────────────────────┐
                    │          Python Side (Bridge)           │
                    ├─────────────────────────────────────────┤
                    │                                         │
    ┌───────────────▼──────────────────────────┐             │
    │  GenericPythonAdapter (BaseAdapter)      │             │
    │                                          │             │
    │  • Library Registry                      │             │
    │  • Dynamic Import System                 │             │
    │  • Function Introspection               │             │
    │  • Type Mapping (Python -> gRPC)        │             │
    │  • Execution Dispatcher                 │             │
    └───────────────┬──────────────────────────┘             │
                    │                                         │
    ┌───────────────▼──────────────────────────┐             │
    │      LibraryLoader                       │             │
    │                                          │             │
    │  • pip install {package}                 │             │
    │  • import {module}                       │             │
    │  • inspect functions/signatures          │             │
    │  • cache module references               │             │
    └───────────────┬──────────────────────────┘             │
                    │                                         │
    ┌───────────────▼──────────────────────────┐             │
    │      FunctionDispatcher                  │             │
    │                                          │             │
    │  • getattr(module, function_name)        │             │
    │  • Argument mapping & validation         │             │
    │  • Result serialization                  │             │
    │  • Error handling & translation          │             │
    └──────────────────────────────────────────┘             │
                    │                                         │
    ┌───────────────▼──────────────────────────┐             │
    │      Loaded Python Libraries             │             │
    │                                          │             │
    │  • docling.document_converter            │             │
    │  • pandas                                │             │
    │  • numpy                                 │             │
    │  • {any pip-installable package}        │             │
    └──────────────────────────────────────────┘             │
                                                              │
                    └─────────────────────────────────────────┘
```

---

## Detailed Requirements

### 1. Configuration System

#### 1.1 Library Definition

```elixir
# config/runtime.exs or config/config.exs
config :snakepit,
  adapter_module: Snakepit.Adapters.PythonGeneric,
  python_libraries: [
    %{
      # Required fields
      name: "docling",                    # Unique identifier
      module: "docling.document_converter", # Python import path
      pip_package: "docling",             # pip package name

      # Optional fields
      version: ">=1.0.0",                 # Version constraint
      functions: nil,                     # nil = auto-discover all, or list specific
      install_on_startup: true,           # pip install if missing
      lazy_load: false,                   # Load on first use vs startup

      # Environment/dependencies
      python_version: ">=3.9",           # Minimum Python version
      system_packages: [],                # apt packages needed (e.g., tesseract)

      # Namespace
      namespace: "docling",              # Command prefix: python.docling.{func}
    },

    # Another example - minimal config
    %{
      name: "pandas",
      module: "pandas",
      pip_package: "pandas"
    }
  ]
```

#### 1.2 Configuration Validation

Snakepit should validate on startup:
- Required fields present
- No duplicate `name` values
- No conflicting `namespace` values
- Python executable exists
- pip is available

---

### 2. Python Side: GenericPythonAdapter

#### 2.1 Module Structure

```python
# priv/python/snakepit_bridge/adapters/generic_python.py

import importlib
import inspect
import subprocess
import sys
from typing import Any, Dict, List, Optional, Callable
from snakepit_bridge.adapters.base import BaseAdapter

class GenericPythonAdapter(BaseAdapter):
    """
    Generic adapter that can load and execute functions from any Python library.

    Handles:
    - Dynamic pip install
    - Module import and caching
    - Function introspection
    - Automatic command registration
    - Type coercion and validation
    """

    def __init__(self):
        super().__init__()
        self.library_registry: Dict[str, LoadedLibrary] = {}
        self.function_cache: Dict[str, Callable] = {}

    def register_library(self, config: Dict[str, Any]) -> None:
        """
        Register a Python library for use.

        Args:
            config: Library configuration dict with keys:
                - name: str
                - module: str (import path)
                - pip_package: str
                - version: Optional[str]
                - functions: Optional[List[str]]
                - install_on_startup: bool
        """
        name = config["name"]

        # Step 1: Ensure library is installed
        if config.get("install_on_startup", True):
            self._ensure_installed(
                config["pip_package"],
                config.get("version")
            )

        # Step 2: Import the module
        module = importlib.import_module(config["module"])

        # Step 3: Discover or load specified functions
        functions = config.get("functions")
        if functions is None:
            # Auto-discover all public functions
            functions = self._discover_functions(module)

        # Step 4: Register each function as a command
        loaded_lib = LoadedLibrary(
            name=name,
            module=module,
            functions={}
        )

        for func_name in functions:
            # Get function reference
            if hasattr(module, func_name):
                func = getattr(module, func_name)

                # Inspect signature
                sig = inspect.signature(func)

                # Create command name: python.{namespace}.{func_name}
                namespace = config.get("namespace", name)
                command_name = f"execute_python_{namespace}_{func_name}"

                # Register as adapter command
                loaded_lib.functions[func_name] = FunctionMetadata(
                    func=func,
                    signature=sig,
                    command_name=command_name
                )

                # Register with BaseAdapter
                self.register_command(
                    command_name,
                    self._create_function_handler(func, sig)
                )

        self.library_registry[name] = loaded_lib

    def _ensure_installed(self, package: str, version: Optional[str] = None) -> None:
        """Install package via pip if not already installed."""
        try:
            # Check if already installed
            importlib.import_module(package.split("[")[0])  # Handle extras like pandas[excel]
        except ImportError:
            # Not installed - install it
            package_spec = f"{package}{version or ''}"
            subprocess.check_call([
                sys.executable,
                "-m", "pip", "install",
                package_spec,
                "--quiet"
            ])

    def _discover_functions(self, module) -> List[str]:
        """
        Auto-discover public functions in a module.

        Returns list of function names that:
        - Don't start with underscore
        - Are callable
        - Are not classes
        """
        functions = []
        for name in dir(module):
            if name.startswith("_"):
                continue

            attr = getattr(module, name)
            if callable(attr) and not inspect.isclass(attr):
                functions.append(name)

        return functions

    def _create_function_handler(self, func: Callable, sig: inspect.Signature):
        """
        Create an async handler for a Python function.

        Returns:
            Async function that:
            1. Maps gRPC args to function parameters
            2. Calls the function
            3. Serializes the result
        """
        async def handler(args: Dict[str, Any]) -> Dict[str, Any]:
            try:
                # Map args to function parameters
                func_args, func_kwargs = self._map_arguments(args, sig)

                # Call function (handle sync/async)
                if inspect.iscoroutinefunction(func):
                    result = await func(*func_args, **func_kwargs)
                else:
                    result = func(*func_args, **func_kwargs)

                # Serialize result
                return {
                    "success": True,
                    "result": self._serialize_result(result)
                }

            except Exception as e:
                return {
                    "success": False,
                    "error": str(e),
                    "error_type": type(e).__name__
                }

        return handler

    def _map_arguments(
        self,
        args: Dict[str, Any],
        sig: inspect.Signature
    ) -> tuple:
        """
        Map gRPC args dict to function (*args, **kwargs).

        Strategy:
        1. Positional args: args["_args"] = [val1, val2, ...]
        2. Keyword args: args[param_name] = value
        3. Type coercion based on signature annotations
        """
        func_args = args.get("_args", [])
        func_kwargs = {
            k: v for k, v in args.items()
            if k != "_args"
        }

        # TODO: Type coercion based on sig.parameters
        # For v1.0, just pass through

        return func_args, func_kwargs

    def _serialize_result(self, result: Any) -> Any:
        """
        Serialize Python result to gRPC-compatible format.

        Handles:
        - Primitives: pass through
        - NumPy arrays: Convert to list
        - Pandas DataFrames: Convert to dict/JSON
        - Custom objects: Use __dict__ or str()
        """
        # NumPy array
        if hasattr(result, "tolist"):
            return result.tolist()

        # Pandas DataFrame
        if hasattr(result, "to_dict"):
            return result.to_dict(orient="records")

        # Already JSON-serializable
        if isinstance(result, (int, float, str, bool, list, dict, type(None))):
            return result

        # Fallback: Convert to dict or str
        if hasattr(result, "__dict__"):
            return result.__dict__

        return str(result)

class LoadedLibrary:
    """Represents a loaded Python library."""
    def __init__(self, name: str, module, functions: Dict[str, 'FunctionMetadata']):
        self.name = name
        self.module = module
        self.functions = functions

class FunctionMetadata:
    """Metadata about a loaded function."""
    def __init__(self, func: Callable, signature: inspect.Signature, command_name: str):
        self.func = func
        self.signature = signature
        self.command_name = command_name
```

---

### 3. Elixir Side: PythonGeneric Adapter

#### 3.1 Adapter Module

```elixir
# lib/snakepit/adapters/python_generic.ex

defmodule Snakepit.Adapters.PythonGeneric do
  @moduledoc """
  Generic Python adapter that can execute functions from any Python library.

  Libraries are configured via application config and loaded on startup.
  Functions are exposed as: "python.{namespace}.{function_name}"

  ## Configuration

      config :snakepit,
        adapter_module: Snakepit.Adapters.PythonGeneric,
        python_libraries: [
          %{
            name: "docling",
            module: "docling.document_converter",
            pip_package: "docling"
          }
        ]

  ## Usage

      {:ok, result} = Snakepit.execute("python.docling.parse_pdf", %{
        file_path: "/path/to/doc.pdf"
      })
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end

  @impl true
  def script_path do
    Path.join(:code.priv_dir(:snakepit), "python/grpc_server.py")
  end

  @impl true
  def script_args do
    [
      "--adapter",
      "snakepit_bridge.adapters.generic_python:GenericPythonAdapter"
    ]
  end

  @impl true
  def supported_commands do
    # Dynamic - build from configured libraries
    libraries = Application.get_env(:snakepit, :python_libraries, [])

    Enum.flat_map(libraries, fn lib_config ->
      namespace = Map.get(lib_config, :namespace, lib_config.name)
      functions = Map.get(lib_config, :functions, ["*"])  # * = all

      Enum.map(functions, fn func ->
        "python.#{namespace}.#{func}"
      end)
    end)
  end

  @impl true
  def validate_command(command, _args) do
    if String.starts_with?(command, "python.") do
      :ok
    else
      {:error, "Command must start with 'python.'"}
    end
  end

  @impl true
  def uses_grpc?, do: true
end
```

#### 3.2 Initialization Hook

```elixir
# lib/snakepit/adapters/python_generic.ex (continued)

defmodule Snakepit.Adapters.PythonGeneric.Initializer do
  @moduledoc """
  Initializes Python libraries on worker startup.

  Sends library configurations to Python worker during init phase.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Get configured libraries
    libraries = Application.get_env(:snakepit, :python_libraries, [])

    {:ok, %{libraries: libraries}, {:continue, :register_libraries}}
  end

  @impl true
  def handle_continue(:register_libraries, state) do
    # Send each library config to Python workers
    # This happens after pool init but before workers accept requests

    Enum.each(state.libraries, fn lib_config ->
      # Send to all workers via special init command
      Snakepit.execute("_internal.register_library", lib_config)
    end)

    {:noreply, state}
  end
end
```

---

### 4. Type System & Mapping

#### 4.1 Supported Type Conversions

| Python Type | Elixir Type | gRPC Type | Notes |
|-------------|-------------|-----------|-------|
| `str` | `String.t()` | `string` | Direct mapping |
| `int` | `integer()` | `int64` | Direct mapping |
| `float` | `float()` | `double` | Direct mapping |
| `bool` | `boolean()` | `bool` | Direct mapping |
| `None` | `nil` | `null` | Direct mapping |
| `list` | `list()` | `repeated` | Recursive |
| `dict` | `map()` | `map` | Keys must be strings |
| `np.ndarray` | `list()` | `bytes` (binary) | `.tolist()` or binary encoding |
| `pd.DataFrame` | `map()` | `string` (JSON) | `.to_dict(orient="records")` |
| `bytes` | `binary()` | `bytes` | Direct mapping |
| Custom class | `map()` | `struct` | Via `.__dict__` or custom serializer |

#### 4.2 Advanced Type Handling

**Large Data (NumPy, Pandas):**
- Use binary serialization for arrays > 10KB
- Automatic threshold detection
- Metadata + binary payload pattern

**Streaming Results:**
- For generators/iterators, auto-detect and stream chunks
- `yield` in Python → streaming callback in Elixir

---

### 5. Error Handling

#### 5.1 Installation Errors

```python
# Python side
try:
    subprocess.check_call([...pip install...])
except subprocess.CalledProcessError as e:
    return {
        "success": False,
        "error": f"Failed to install {package}: {e.stderr}",
        "error_type": "InstallationError"
    }
```

#### 5.2 Import Errors

```python
try:
    module = importlib.import_module(config["module"])
except ImportError as e:
    return {
        "success": False,
        "error": f"Could not import {config['module']}: {str(e)}",
        "error_type": "ImportError",
        "hint": "Check module name and pip package installation"
    }
```

#### 5.3 Function Call Errors

```python
try:
    result = func(*args, **kwargs)
except TypeError as e:
    # Wrong arguments
    return {
        "success": False,
        "error": f"Invalid arguments: {str(e)}",
        "error_type": "TypeError",
        "expected_signature": str(sig)
    }
except Exception as e:
    # Function execution error
    return {
        "success": False,
        "error": str(e),
        "error_type": type(e).__name__,
        "traceback": traceback.format_exc()
    }
```

---

### 6. Advanced Features

#### 6.1 Lazy Loading

```elixir
# Config
%{
  name: "heavy_library",
  module: "transformers",
  pip_package: "transformers",
  lazy_load: true  # Don't import until first use
}
```

```python
# Python implementation
def _get_or_load_library(self, name: str) -> LoadedLibrary:
    if name not in self.library_registry:
        # Lazy load now
        config = self.pending_libraries[name]
        self.register_library(config)

    return self.library_registry[name]
```

#### 6.2 Function Aliasing

```elixir
# Config
%{
  name: "docling",
  module: "docling.document_converter",
  pip_package: "docling",
  aliases: %{
    "parse" => "parse_pdf",  # python.docling.parse → parse_pdf()
    "convert" => "convert_to_markdown"
  }
}
```

#### 6.3 Middleware/Hooks

```python
class GenericPythonAdapter(BaseAdapter):
    def __init__(self):
        super().__init__()
        self.before_execute_hooks: List[Callable] = []
        self.after_execute_hooks: List[Callable] = []

    def add_before_hook(self, hook: Callable):
        """Add hook that runs before function execution."""
        self.before_execute_hooks.append(hook)

    def add_after_hook(self, hook: Callable):
        """Add hook that runs after function execution."""
        self.after_execute_hooks.append(hook)
```

**Use cases:**
- Logging: Log all library calls
- Metrics: Track execution time per library
- Caching: Cache results for pure functions
- Validation: Pre-validate arguments

---

### 7. Security Considerations

#### 7.1 Sandboxing

**Problem:** Arbitrary Python code execution is dangerous.

**Mitigations:**
1. **Whitelist approach:** Only configured libraries allowed
2. **No eval/exec:** Never use `eval()` or `exec()`
3. **Subprocess isolation:** Python runs in separate process
4. **Resource limits:** CPU/memory limits via cgroups
5. **Network restrictions:** Firewall rules for worker processes

#### 7.2 Configuration Validation

```elixir
defmodule Snakepit.Config.LibraryValidator do
  def validate!(config) do
    # Check for malicious patterns
    Enum.each(config, fn lib ->
      # No shell injection characters in pip package
      if String.contains?(lib.pip_package, [";", "|", "&", "`"]) do
        raise ArgumentError, "Invalid pip package name: #{lib.pip_package}"
      end

      # Valid Python module name
      unless lib.module =~ ~r/^[a-zA-Z0-9_.]+$/ do
        raise ArgumentError, "Invalid module name: #{lib.module}"
      end
    end)
  end
end
```

---

### 8. Performance Optimization

#### 8.1 Module Caching

```python
# Cache imported modules globally across all workers
_MODULE_CACHE: Dict[str, Any] = {}

def _get_cached_module(import_path: str):
    if import_path not in _MODULE_CACHE:
        _MODULE_CACHE[import_path] = importlib.import_module(import_path)
    return _MODULE_CACHE[import_path]
```

#### 8.2 Function Reference Caching

```python
# Don't re-introspect functions on every call
_FUNCTION_CACHE: Dict[str, Tuple[Callable, inspect.Signature]] = {}
```

#### 8.3 Compiled Argument Mappers

```python
# Pre-compile argument mapping logic for each function
def _compile_arg_mapper(sig: inspect.Signature) -> Callable:
    """
    Generate optimized argument mapper based on signature.

    Returns callable that maps gRPC args to (*args, **kwargs).
    """
    # Analyze signature once, generate fast mapper
    param_names = list(sig.parameters.keys())

    def mapper(args: Dict[str, Any]):
        positional = args.get("_args", [])
        keywords = {k: v for k, v in args.items() if k in param_names}
        return positional, keywords

    return mapper
```

---

### 9. Testing Strategy

#### 9.1 Unit Tests

```python
# test_generic_python_adapter.py

def test_library_registration():
    adapter = GenericPythonAdapter()
    config = {
        "name": "math",
        "module": "math",
        "pip_package": "math",  # Built-in, no install needed
        "functions": ["sqrt", "ceil", "floor"]
    }

    adapter.register_library(config)

    assert "math" in adapter.library_registry
    assert len(adapter.library_registry["math"].functions) == 3

def test_function_execution():
    # Test calling math.sqrt
    result = await adapter.execute_python_math_sqrt({"_args": [16]})
    assert result["success"] == True
    assert result["result"] == 4.0
```

#### 9.2 Integration Tests

```elixir
# test/snakepit/adapters/python_generic_test.exs

defmodule Snakepit.Adapters.PythonGenericTest do
  use ExUnit.Case

  setup do
    # Configure test library
    Application.put_env(:snakepit, :python_libraries, [
      %{
        name: "test_lib",
        module: "json",  # Use stdlib json for testing
        pip_package: "json"
      }
    ])

    start_supervised!(Snakepit.Supervisor)
    :ok
  end

  test "can execute stdlib json.dumps" do
    {:ok, result} = Snakepit.execute("python.test_lib.dumps", %{
      "_args" => [%{"key" => "value"}]
    })

    assert result["success"] == true
    assert result["result"] =~ "key"
  end
end
```

---

### 10. Documentation Requirements

#### 10.1 User Guide

**`guides/GENERIC_PYTHON_ADAPTER.md`**

Topics:
- How to add a new library (config examples)
- Function calling patterns
- Type mapping guide
- Troubleshooting common errors
- Security best practices

#### 10.2 API Reference

**Module docs:**
- `Snakepit.Adapters.PythonGeneric` - Elixir adapter
- `snakepit_bridge.adapters.generic_python` - Python adapter

**Function docs:**
- All public functions with typespecs
- Examples for each major feature

---

### 11. Implementation Roadmap

#### Phase 1: Foundation (Week 1)
- [ ] Create `GenericPythonAdapter` base class
- [ ] Implement library registration
- [ ] Implement function discovery
- [ ] Basic command execution (no type mapping yet)
- [ ] Unit tests for Python side

#### Phase 2: Elixir Integration (Week 2)
- [ ] Create `Snakepit.Adapters.PythonGeneric`
- [ ] Configuration loading and validation
- [ ] Library initialization hook
- [ ] Integration tests
- [ ] Documentation

#### Phase 3: Type System (Week 3)
- [ ] Advanced type mapping (NumPy, Pandas)
- [ ] Binary serialization for large data
- [ ] Streaming support for generators
- [ ] Error handling improvements

#### Phase 4: Production Features (Week 4)
- [ ] Performance optimizations (caching)
- [ ] Security hardening
- [ ] Monitoring/telemetry hooks
- [ ] Production testing with Docling

#### Phase 5: Polish & Release (Week 5)
- [ ] Complete documentation
- [ ] Example applications
- [ ] Performance benchmarks
- [ ] Release as Snakepit v0.7.0

---

### 12. Success Metrics

**Development Metrics:**
- ✅ Add new Python library in < 5 minutes (just config)
- ✅ Zero custom adapter code for 90% of libraries
- ✅ Type mapping works for 95% of common types
- ✅ No memory leaks with 10+ libraries loaded

**Performance Metrics:**
- Library load time: < 1s per library
- Function call overhead: < 5ms vs direct Python call
- Memory overhead: < 50MB per loaded library
- Concurrent requests: Handle 100+ req/s per library

**User Experience:**
- Clear error messages for common issues
- Auto-install works 99% of time
- Type errors caught before execution when possible

---

### 13. Example Use Cases

#### 13.1 Docling Integration

```elixir
# Configuration
config :snakepit,
  python_libraries: [
    %{
      name: "docling",
      module: "docling.document_converter",
      pip_package: "docling",
      version: ">=1.0.0"
    }
  ]

# Usage
{:ok, parsed} = Snakepit.execute("python.docling.parse_pdf", %{
  "file_path" => "/intelligence/report.pdf",
  "output_format" => "markdown"
})

# Result
parsed = %{
  "success" => true,
  "result" => %{
    "content" => "# Intelligence Brief\n\n...",
    "tables" => [...],
    "metadata" => %{"pages" => 15}
  }
}
```

#### 13.2 Pandas Data Processing

```elixir
# Load CSV
{:ok, df} = Snakepit.execute("python.pandas.read_csv", %{
  "filepath_or_buffer" => "/data/sales.csv"
})

# Describe data
{:ok, stats} = Snakepit.execute("python.pandas.describe", %{
  "_args" => [df["result"]]
})
```

#### 13.3 Transformers NLP

```elixir
config :snakepit,
  python_libraries: [
    %{
      name: "transformers",
      module: "transformers",
      pip_package: "transformers",
      lazy_load: true  # Heavy library, load on demand
    }
  ]

# Use
{:ok, embeddings} = Snakepit.execute("python.transformers.pipeline", %{
  "task" => "feature-extraction",
  "model" => "sentence-transformers/all-MiniLM-L6-v2"
})
```

---

### 14. Open Questions

1. **Versioning:** How to handle library version conflicts?
   - **Answer:** Use virtual environments per library? Or require user to manage?

2. **State Management:** How to handle stateful libraries (e.g., TensorFlow sessions)?
   - **Answer:** Support object storage in session context? `ctx.store("model", model_obj)`

3. **Async Libraries:** How to handle async Python functions?
   - **Answer:** Detect with `inspect.iscoroutinefunction()` and await

4. **Streaming:** How to handle generators/iterators?
   - **Answer:** Auto-detect and convert to gRPC streaming

5. **Memory Management:** How to prevent memory leaks from loaded libraries?
   - **Answer:** Worker TTL recycling + explicit unload commands

---

### 15. Alternatives Considered

#### Alternative 1: Code Generation

**Approach:** Generate Elixir/Python adapter code from library signatures.

**Pros:** Type-safe, optimized code
**Cons:** Complex tooling, still requires per-library setup

**Decision:** Rejected - defeats purpose of zero-code integration

#### Alternative 2: RPC Layer (e.g., JSON-RPC)

**Approach:** Generic JSON-RPC bridge instead of gRPC.

**Pros:** Simpler protocol
**Cons:** No streaming, worse performance, no type info

**Decision:** Rejected - gRPC is already working well in Snakepit

#### Alternative 3: Python-as-a-Service

**Approach:** Run Python as separate service, not worker pool.

**Pros:** Isolation, easier scaling
**Cons:** Breaks Snakepit's pooling model, network overhead

**Decision:** Rejected - keep within Snakepit architecture

---

## Conclusion

This design enables Snakepit to become a true **universal Python bridge** for Elixir applications. With this system:

- **Nordic Road** can integrate Docling for document intelligence
- **Any Elixir app** can use any Python library with minimal config
- **Future integrations** become trivial (just add to config)

**Next Step:** Implement Phase 1 (Foundation) in Snakepit repository.

---

**Document Status:** Complete - Ready for Implementation
**Review Required:** Snakepit maintainer approval
**Target Release:** Snakepit v0.7.0 (December 2025)
