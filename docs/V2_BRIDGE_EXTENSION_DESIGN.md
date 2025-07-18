# V2 Bridge Extension Design: Dynamic Python Interop

## Executive Summary

This document presents a design for extending the Snakepit V2 bridge to achieve dynamic Python method invocation while strictly adhering to the Open-Closed Principle (OCP). Rather than modifying the core V2 infrastructure, we enhance it through its well-designed extension points to create a universal Python interop layer.

The V2 bridge already provides an exceptional foundation with clean separation of concerns, extensible adapter interfaces, and production-ready infrastructure. Our enhancement leverages these extension points to add dynamic capabilities without modifying any existing code.

## V2 Bridge Architecture Analysis

### Current V2 Strengths

The V2 bridge implementation demonstrates excellent architectural principles:

1. **Behavior-Based Extensibility**: Clean `Snakepit.Adapter` interface with required and optional callbacks
2. **Protocol Independence**: Robust wire protocol separate from application logic  
3. **Pool Infrastructure**: High-performance concurrent worker management
4. **Session Management**: Stateful session handling with TTL expiration
5. **Python Package Structure**: Professional package layout with proper installation modes
6. **OCP Compliance**: Core components protected while providing extensive extension points

### Extension Points Identified

The V2 architecture provides multiple extension points:

#### 1. Adapter Level Extensions
- **New Adapter Implementations**: Custom `Snakepit.Adapter` modules
- **Command Extensions**: Additional commands via `supported_commands/0`
- **Processing Hooks**: Custom logic in `prepare_args/2` and `process_response/2`

#### 2. Python Handler Extensions
- **Custom Command Handlers**: Inherit from `BaseCommandHandler`
- **Framework Integration**: Plugin system for different Python libraries
- **Command Registration**: Dynamic command addition via `register_command/1`

#### 3. Infrastructure Extensions
- **Session Strategies**: Custom session management approaches
- **Monitoring Integration**: Telemetry and observability extensions
- **Protocol Variants**: Additional wire protocol support

## Enhancement Design: Dynamic Python Interop

### Goal

Create a universal Python interop system that provides:
1. **Dynamic Method Invocation**: Call any Python method without hardcoding
2. **Object Persistence**: Store and reuse Python objects across calls
3. **Framework Agnostic**: Support any Python library (DSPy, Transformers, etc.)
4. **Zero Modification**: Extend V2 without changing existing code
5. **Backward Compatibility**: Maintain all current functionality

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Existing V2 Bridge (Unchanged)               │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ Snakepit.Adapter│  │ Protocol Handler│  │  Pool Manager   │ │
│  │   (Behavior)    │  │  (Wire Protocol)│  │ (Concurrency)   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│                     Extension Layer (New)                      │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │           Enhanced Python Adapter                          ││
│  │                                                             ││
│  │  ┌─────────────────┐  ┌─────────────────┐                  ││
│  │  │Legacy Commands  │  │Dynamic Commands │                  ││
│  │  │                 │  │                 │                  ││
│  │  │• create_program │  │• call           │                  ││
│  │  │• execute_program│  │• store          │                  ││
│  │  │• configure_lm   │  │• retrieve       │                  ││
│  │  └─────────────────┘  └─────────────────┘                  ││
│  │                                                             ││
│  │  ┌─────────────────────────────────────────────────────────┐││
│  │  │            Command Translation Layer                    │││
│  │  │                                                         │││
│  │  │  Legacy → Dynamic Translation                           │││
│  │  │  create_program → call("dspy.Predict", ...)            │││
│  │  │  execute_program → call("stored.X.__call__", ...)      │││
│  │  └─────────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────┤
│                  Enhanced Python Bridge (New)                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              Dynamic Command Handler                        ││
│  │                                                             ││
│  │  ┌─────────────────┐  ┌─────────────────┐                  ││
│  │  │Method Invoker   │  │Object Manager   │                  ││
│  │  │                 │  │                 │                  ││
│  │  │• Dynamic calls  │  │• Store/retrieve │                  ││
│  │  │• Attribute acc. │  │• Lifecycle mgmt │                  ││
│  │  │• Class creation │  │• Cross-session  │                  ││
│  │  └─────────────────┘  └─────────────────┘                  ││
│  │                                                             ││
│  │  ┌─────────────────┐  ┌─────────────────┐                  ││
│  │  │Framework Plugins│  │Smart Serializer │                  ││
│  │  │                 │  │                 │                  ││
│  │  │• DSPy support   │  │• Type awareness │                  ││
│  │  │• Auto-discovery │  │• Framework opts │                  ││
│  │  │• Plugin system  │  │• Error wrapping │                  ││
│  │  └─────────────────┘  └─────────────────┘                  ││
│  └─────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────┤
│                    Target Libraries                            │
│                                                                 │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐            │
│  │  DSPy   │  │Transform│  │ OpenAI  │  │ Custom  │            │
│  │         │  │  ers    │  │         │  │Libraries│            │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Strategy

### Phase 1: Enhanced Adapter Extension

Create a new adapter that extends the existing patterns without modification:

**File**: `snakepit/lib/snakepit/adapters/enhanced_python.ex`

```elixir
defmodule Snakepit.Adapters.EnhancedPython do
  @moduledoc """
  Enhanced Python adapter with dynamic method invocation capabilities.
  
  Extends the V2 bridge architecture to support universal Python interop
  while maintaining full backward compatibility with existing adapters.
  
  Features:
  - Dynamic method calls on any Python object/module
  - Object persistence across calls and sessions
  - Framework-agnostic design supporting any Python library
  - Automatic translation of legacy commands to dynamic calls
  - Smart serialization with framework-specific optimizations
  """
  
  @behaviour Snakepit.Adapter
  
  # Legacy commands from existing DSPy adapter
  @legacy_commands [
    "ping", "configure_lm", "create_program", "execute_program",
    "get_program", "list_programs", "delete_program", "clear_session"
  ]
  
  # New dynamic commands
  @dynamic_commands [
    "call", "store", "retrieve", "list_stored", "delete_stored", 
    "pipeline", "inspect"
  ]
  
  @impl true
  def executable_path do
    System.find_executable("python3") || System.find_executable("python")
  end
  
  @impl true
  def script_path do
    case :code.priv_dir(:snakepit) do
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv", "python", "enhanced_bridge.py"])
      priv_dir ->
        Path.join(priv_dir, "python/enhanced_bridge.py")
    end
  end
  
  @impl true
  def script_args do
    ["--mode", "enhanced-worker"]
  end
  
  @impl true
  def supported_commands do
    @legacy_commands ++ @dynamic_commands
  end
  
  @impl true
  def validate_command(command, args) when command in @dynamic_commands do
    validate_dynamic_command(command, args)
  end
  
  def validate_command(command, args) when command in @legacy_commands do
    # Delegate to existing validation patterns
    validate_legacy_command(command, args)
  end
  
  def validate_command(command, _args) do
    {:error, "unsupported command '#{command}'. Supported: #{Enum.join(supported_commands(), ", ")}"}
  end
  
  @impl true
  def prepare_args(command, args) when command in @legacy_commands do
    # Transform legacy commands to dynamic calls
    translate_legacy_to_dynamic(command, args)
  end
  
  def prepare_args(command, args) when command in @dynamic_commands do
    # Pass through dynamic commands with standard preparation
    args |> stringify_keys() |> add_metadata(command)
  end
  
  @impl true
  def process_response(command, response) when command in @legacy_commands do
    # Process dynamic responses back to legacy format
    translate_dynamic_to_legacy(command, response)
  end
  
  def process_response(_command, response) do
    # Standard dynamic response processing
    case response do
      %{"status" => "ok"} = resp -> {:ok, resp}
      %{"status" => "error", "error" => error} -> {:error, error}
      other -> {:ok, other}
    end
  end
  
  # Translation functions (implementing backward compatibility)
  defp translate_legacy_to_dynamic("create_program", args) do
    program_id = get_field(args, "id")
    signature = get_field(args, "signature")
    
    %{
      "command" => "call",
      "target" => "dspy.Predict",
      "kwargs" => %{"signature" => convert_signature_to_dspy_format(signature)},
      "store_as" => program_id,
      "legacy_command" => "create_program"
    }
  end
  
  defp translate_legacy_to_dynamic("execute_program", args) do
    program_id = get_field(args, "program_id")
    inputs = get_field(args, "inputs")
    
    %{
      "command" => "call", 
      "target" => "stored.#{program_id}.__call__",
      "kwargs" => inputs,
      "legacy_command" => "execute_program"
    }
  end
  
  defp translate_legacy_to_dynamic("configure_lm", args) do
    %{
      "command" => "call",
      "target" => "dspy.configure", 
      "kwargs" => args,
      "legacy_command" => "configure_lm"
    }
  end
  
  # Additional translation functions...
  
  # Dynamic command validation
  defp validate_dynamic_command("call", args) do
    target = get_field(args, "target")
    if is_binary(target) and String.length(target) > 0 do
      :ok
    else
      {:error, "call command requires valid target string"}
    end
  end
  
  defp validate_dynamic_command("store", args) do
    id = get_field(args, "id")
    if is_binary(id) and String.length(id) > 0 do
      :ok
    else
      {:error, "store command requires valid id string"}
    end
  end
  
  # Additional validation functions...
  
  # Helper functions
  defp get_field(args, field) do
    args[field] || args[String.to_atom(field)]
  end
  
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end
  
  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end
  
  defp stringify_keys(value), do: value
  
  defp add_metadata(args, command) do
    Map.merge(args, %{
      "bridge_version" => "enhanced-v2",
      "command_type" => if command in @legacy_commands, do: "legacy", else: "dynamic",
      "timestamp" => System.system_time(:millisecond)
    })
  end
end
```

### Phase 2: Enhanced Python Bridge

Create a new Python bridge that extends the V2 package structure:

**File**: `snakepit/priv/python/enhanced_bridge.py`

```python
#!/usr/bin/env python3
"""
Enhanced Python Bridge for Snakepit V2

Extends the V2 bridge architecture with dynamic method invocation while
maintaining full compatibility with existing command patterns.

Features:
- Universal Python method calls via dynamic invocation
- Object persistence and lifecycle management
- Framework plugin system for optimized integrations
- Smart serialization with type awareness
- Backward compatibility with existing bridges

Architecture:
- Builds on V2 BaseCommandHandler pattern
- Extends rather than replaces existing functionality
- Maintains the same wire protocol and deployment modes
- Zero changes to core V2 infrastructure
"""

import sys
import importlib
import inspect
from typing import Dict, Any, Optional, Union, List
from abc import ABC, abstractmethod

# Import V2 bridge foundation
from snakepit_bridge.core import BaseCommandHandler, ProtocolHandler
from snakepit_bridge.adapters.generic import GenericCommandHandler


class FrameworkPlugin(ABC):
    """Abstract base for framework-specific plugins."""
    
    @abstractmethod
    def name(self) -> str:
        """Return framework name."""
        pass
    
    @abstractmethod
    def load(self) -> Any:
        """Load and return the framework."""
        pass
    
    def configure(self, config: Dict[str, Any]) -> Any:
        """Framework-specific configuration."""
        return None
    
    def serialize_result(self, obj: Any) -> Optional[Dict[str, Any]]:
        """Framework-specific serialization. Return None for default."""
        return None


class DSPyPlugin(FrameworkPlugin):
    """DSPy framework plugin."""
    
    def name(self) -> str:
        return "dspy"
    
    def load(self) -> Any:
        import dspy
        return dspy
    
    def configure(self, config: Dict[str, Any]) -> Any:
        """Configure DSPy with Gemini or other providers."""
        if config.get("provider") == "google":
            return self._configure_gemini(config)
        else:
            # Standard DSPy configuration
            dspy = self.load()
            return dspy.configure(**config)
    
    def _configure_gemini(self, config: Dict[str, Any]) -> Any:
        """DSPy-specific Gemini configuration."""
        dspy = self.load()
        api_key = config.get("api_key")
        model = config.get("model", "gemini-2.0-flash-exp")
        
        lm = dspy.LM(f"gemini/{model}", api_key=api_key)
        dspy.configure(lm=lm)
        return lm
    
    def serialize_result(self, obj: Any) -> Optional[Dict[str, Any]]:
        """DSPy-specific serialization for Prediction objects."""
        if hasattr(obj, '__class__') and obj.__class__.__name__ == "Prediction":
            return self._serialize_prediction(obj)
        return None
    
    def _serialize_prediction(self, prediction: Any) -> Dict[str, Any]:
        """Extract prediction data for easy access."""
        attrs = {}
        prediction_data = {}
        
        # Extract attributes
        if hasattr(prediction, '__dict__'):
            for key, value in prediction.__dict__.items():
                if not key.startswith('_'):
                    try:
                        attrs[key] = self._serialize_value(value)
                        if isinstance(value, (str, int, float, bool)):
                            prediction_data[key] = value
                    except:
                        attrs[key] = {"type": "str", "value": str(value)}
                        prediction_data[key] = str(value)
        
        # Extract from _store if available
        if hasattr(prediction, '_store') and isinstance(prediction._store, dict):
            for key, value in prediction._store.items():
                if isinstance(value, (str, int, float, bool)):
                    prediction_data[key] = value
                else:
                    prediction_data[key] = str(value)
        
        return {
            "type": "Prediction",
            "module": "dspy",
            "attributes": attrs,
            "prediction_data": prediction_data,
            "string_repr": str(prediction)
        }
    
    def _serialize_value(self, value: Any) -> Dict[str, Any]:
        """Serialize individual values."""
        if isinstance(value, (str, int, float, bool)):
            return {"type": type(value).__name__, "value": value}
        elif value is None:
            return {"type": "NoneType", "value": None}
        else:
            return {"type": "str", "value": str(value)}


class EnhancedCommandHandler(BaseCommandHandler):
    """
    Enhanced command handler with dynamic method invocation.
    
    Extends the V2 BaseCommandHandler to add dynamic capabilities
    while maintaining compatibility with existing command patterns.
    """
    
    def __init__(self):
        super().__init__()
        self.stored_objects: Dict[str, Any] = {}
        self.framework_plugins: Dict[str, FrameworkPlugin] = {}
        self.namespaces: Dict[str, Any] = {}
        
        # Auto-discover and load framework plugins
        self._discover_frameworks()
    
    def _register_commands(self):
        """Register both legacy and dynamic commands."""
        # Legacy commands for backward compatibility
        self.register_command("ping", self.handle_ping)
        self.register_command("configure_lm", self.handle_configure_lm)
        self.register_command("create_program", self.handle_create_program)
        self.register_command("execute_program", self.handle_execute_program)
        self.register_command("get_program", self.handle_get_program)
        self.register_command("list_programs", self.handle_list_programs)
        self.register_command("delete_program", self.handle_delete_program)
        self.register_command("clear_session", self.handle_clear_session)
        
        # Dynamic commands
        self.register_command("call", self.handle_call)
        self.register_command("store", self.handle_store)
        self.register_command("retrieve", self.handle_retrieve)
        self.register_command("list_stored", self.handle_list_stored)
        self.register_command("delete_stored", self.handle_delete_stored)
        self.register_command("pipeline", self.handle_pipeline)
        self.register_command("inspect", self.handle_inspect)
    
    def _discover_frameworks(self):
        """Auto-discover available Python frameworks."""
        plugins = [
            DSPyPlugin(),
            # Add more plugins here as needed
        ]
        
        for plugin in plugins:
            try:
                framework = plugin.load()
                self.framework_plugins[plugin.name()] = plugin
                self.namespaces[plugin.name()] = framework
                print(f"Framework loaded: {plugin.name()}", file=sys.stderr)
            except ImportError:
                print(f"Framework not available: {plugin.name()}", file=sys.stderr)
    
    def handle_call(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Universal method invocation handler.
        
        Supports:
        - framework.method(...)
        - framework.Class(...)
        - stored.object.method(...)
        - any.python.path
        """
        try:
            target = args.get("target")
            call_args = args.get("args", [])
            call_kwargs = args.get("kwargs", {})
            store_as = args.get("store_as")
            
            if not target:
                return {"status": "error", "error": "Missing 'target' parameter"}
            
            # Execute the dynamic call
            result = self._execute_dynamic_call(target, call_args, call_kwargs)
            
            # Store result if requested
            if store_as:
                self.stored_objects[store_as] = result
            
            # Smart serialization
            serialized = self._smart_serialize(result, target)
            
            return {
                "status": "ok",
                "result": serialized,
                "stored_as": store_as,
                "target": target,
                "timestamp": time.time()
            }
            
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "traceback": traceback.format_exc()
            }
    
    def _execute_dynamic_call(self, target: str, args: List[Any], kwargs: Dict[str, Any]) -> Any:
        """Execute dynamic method calls on any Python object."""
        parts = target.split('.')
        
        if parts[0] == "stored":
            # Call on stored object: stored.object_id.method
            if len(parts) < 3:
                raise ValueError("Stored calls need format: stored.object_id.method")
            
            object_id = parts[1]
            if object_id not in self.stored_objects:
                raise ValueError(f"Stored object '{object_id}' not found")
            
            obj = self.stored_objects[object_id]
            
            # Navigate through attributes and call final method
            current = obj
            for part in parts[2:-1]:
                current = getattr(current, part)
            
            if len(parts) > 2:
                method = getattr(current, parts[-1])
                return method(*args, **kwargs)
            else:
                return current
        
        else:
            # Call on namespace: framework.method, framework.Class, etc.
            namespace_name = parts[0]
            
            # Try registered frameworks first
            if namespace_name in self.namespaces:
                namespace = self.namespaces[namespace_name]
            else:
                # Try importing as module
                try:
                    namespace = importlib.import_module(namespace_name)
                    self.namespaces[namespace_name] = namespace
                except ImportError:
                    raise ValueError(f"Cannot import namespace: {namespace_name}")
            
            # Navigate to target
            current = namespace
            for part in parts[1:]:
                current = getattr(current, part)
            
            # Execute call
            if callable(current):
                result = current(*args, **kwargs)
                
                # Framework-specific post-processing
                if namespace_name in self.framework_plugins:
                    plugin = self.framework_plugins[namespace_name]
                    configured = plugin.configure(kwargs) if hasattr(plugin, 'configure') else None
                    if configured:
                        # Store configured objects for later use
                        self.stored_objects[f"current_{namespace_name}_config"] = configured
                
                return result
            else:
                return current
    
    def _smart_serialize(self, obj: Any, target: str) -> Dict[str, Any]:
        """Smart serialization with framework-specific optimizations."""
        # Try framework-specific serialization first
        for plugin in self.framework_plugins.values():
            serialized = plugin.serialize_result(obj)
            if serialized:
                return serialized
        
        # Fallback to generic serialization
        return self._generic_serialize(obj)
    
    def _generic_serialize(self, obj: Any) -> Dict[str, Any]:
        """Generic object serialization."""
        if obj is None:
            return {"type": "NoneType", "value": None}
        
        if isinstance(obj, (str, int, float, bool)):
            return {"type": type(obj).__name__, "value": obj}
        
        if isinstance(obj, (list, tuple)):
            return {
                "type": type(obj).__name__,
                "value": [self._generic_serialize(item) for item in obj]
            }
        
        if isinstance(obj, dict):
            return {
                "type": "dict",
                "value": {k: self._generic_serialize(v) for k, v in obj.items()}
            }
        
        # Complex objects
        try:
            if hasattr(obj, '__dict__'):
                attrs = {}
                for key, value in obj.__dict__.items():
                    if not key.startswith('_'):
                        try:
                            attrs[key] = self._generic_serialize(value)
                        except:
                            attrs[key] = {"type": "str", "value": str(value)}
                
                return {
                    "type": type(obj).__name__,
                    "module": getattr(obj.__class__, '__module__', 'unknown'),
                    "attributes": attrs,
                    "string_repr": str(obj)
                }
            else:
                return {
                    "type": type(obj).__name__,
                    "value": str(obj)
                }
        except Exception as e:
            return {
                "type": "SerializationError",
                "error": str(e),
                "string_repr": str(obj)
            }
    
    # Legacy command handlers (for backward compatibility)
    def handle_configure_lm(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy configure_lm command."""
        # Translate to dynamic call
        if args.get("provider") == "google":
            plugin = self.framework_plugins.get("dspy")
            if plugin:
                try:
                    result = plugin.configure(args)
                    return {"status": "ok", "message": "LM configured successfully"}
                except Exception as e:
                    return {"status": "error", "error": str(e)}
        
        # Fallback to generic configuration
        return self.handle_call({
            "target": "dspy.configure",
            "kwargs": args
        })
    
    def handle_create_program(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy create_program command."""
        program_id = args.get("id")
        signature = args.get("signature")
        
        # Convert signature and create program
        dspy_signature = self._convert_signature_format(signature)
        
        return self.handle_call({
            "target": "dspy.Predict",
            "kwargs": {"signature": dspy_signature},
            "store_as": program_id
        })
    
    def handle_execute_program(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy execute_program command."""
        program_id = args.get("program_id")
        inputs = args.get("inputs", {})
        
        result = self.handle_call({
            "target": f"stored.{program_id}.__call__",
            "kwargs": inputs
        })
        
        # Transform result to legacy format
        if result.get("status") == "ok":
            result_data = result.get("result", {})
            if isinstance(result_data, dict) and "prediction_data" in result_data:
                return {
                    "status": "ok",
                    "outputs": result_data["prediction_data"]
                }
        
        return result
    
    # Additional legacy handlers...
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Enhanced ping with framework status."""
        return {
            "status": "ok",
            "bridge_type": "enhanced-v2",
            "frameworks_available": list(self.framework_plugins.keys()),
            "stored_objects": len(self.stored_objects),
            "uptime": time.time() - self.start_time,
            "requests_handled": self.request_count
        }
    
    # Storage management commands
    def handle_store(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Store an object for later retrieval."""
        object_id = args.get("id")
        value = args.get("value")
        
        if not object_id:
            return {"status": "error", "error": "Missing 'id' parameter"}
        
        self.stored_objects[object_id] = value
        return {
            "status": "ok",
            "message": f"Object stored as '{object_id}'",
            "stored_objects": len(self.stored_objects)
        }
    
    def handle_retrieve(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Retrieve a stored object."""
        object_id = args.get("id")
        
        if not object_id:
            return {"status": "error", "error": "Missing 'id' parameter"}
        
        if object_id not in self.stored_objects:
            return {"status": "error", "error": f"Object '{object_id}' not found"}
        
        obj = self.stored_objects[object_id]
        serialized = self._smart_serialize(obj, f"stored.{object_id}")
        
        return {
            "status": "ok",
            "object": serialized
        }
    
    def handle_list_stored(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """List all stored objects."""
        return {
            "status": "ok",
            "stored_objects": list(self.stored_objects.keys()),
            "count": len(self.stored_objects)
        }
    
    def handle_delete_stored(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Delete a stored object."""
        object_id = args.get("id")
        
        if not object_id:
            return {"status": "error", "error": "Missing 'id' parameter"}
        
        if object_id in self.stored_objects:
            del self.stored_objects[object_id]
            return {"status": "ok", "message": f"Object '{object_id}' deleted"}
        else:
            return {"status": "error", "error": f"Object '{object_id}' not found"}
    
    def handle_pipeline(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a sequence of calls as a pipeline."""
        steps = args.get("steps", [])
        results = []
        
        for i, step in enumerate(steps):
            try:
                if isinstance(step, dict) and "target" in step:
                    result = self.handle_call(step)
                    results.append(result)
                    
                    if result.get("status") != "ok":
                        return {
                            "status": "error",
                            "error": f"Pipeline failed at step {i}",
                            "step_result": result,
                            "completed_steps": results
                        }
                else:
                    return {
                        "status": "error",
                        "error": f"Invalid step {i}: missing 'target'"
                    }
            except Exception as e:
                return {
                    "status": "error",
                    "error": f"Pipeline failed at step {i}: {str(e)}",
                    "completed_steps": results
                }
        
        return {
            "status": "ok",
            "pipeline_results": results,
            "steps_completed": len(results)
        }
    
    def handle_inspect(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Inspect objects and provide metadata."""
        target = args.get("target")
        
        if not target:
            return {"status": "error", "error": "Missing 'target' parameter"}
        
        try:
            if target.startswith("stored."):
                object_id = target.split(".", 1)[1]
                if object_id not in self.stored_objects:
                    return {"status": "error", "error": f"Object '{object_id}' not found"}
                obj = self.stored_objects[object_id]
            else:
                # Try to resolve the target
                parts = target.split('.')
                if parts[0] in self.namespaces:
                    obj = self.namespaces[parts[0]]
                    for part in parts[1:]:
                        obj = getattr(obj, part)
                else:
                    return {"status": "error", "error": f"Cannot resolve target: {target}"}
            
            # Gather inspection data
            inspection = {
                "type": type(obj).__name__,
                "module": getattr(obj.__class__, '__module__', 'unknown'),
                "callable": callable(obj),
                "string_repr": str(obj)
            }
            
            if hasattr(obj, '__doc__') and obj.__doc__:
                inspection["docstring"] = obj.__doc__
            
            if callable(obj):
                try:
                    sig = inspect.signature(obj)
                    inspection["signature"] = str(sig)
                except:
                    pass
            
            if hasattr(obj, '__dict__'):
                inspection["attributes"] = list(obj.__dict__.keys())
            
            return {
                "status": "ok",
                "inspection": inspection
            }
            
        except Exception as e:
            return {
                "status": "error",
                "error": str(e)
            }
    
    # Utility methods
    def _convert_signature_format(self, signature):
        """Convert Elixir signature format to DSPy format."""
        if isinstance(signature, str):
            return signature
        
        if isinstance(signature, dict):
            inputs = signature.get("inputs", [])
            outputs = signature.get("outputs", [])
            
            input_names = [inp.get("name", "input") for inp in inputs]
            output_names = [out.get("name", "output") for out in outputs]
            
            input_str = ", ".join(input_names)
            output_str = ", ".join(output_names)
            
            return f"{input_str} -> {output_str}"
        
        return "input -> output"  # fallback


def main():
    """Main entry point for enhanced bridge."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Enhanced Python Bridge for Snakepit V2")
    parser.add_argument("--mode", default="enhanced-worker", help="Bridge mode")
    args = parser.parse_args()
    
    if args.mode == "enhanced-worker":
        # Use enhanced command handler
        handler = ProtocolHandler(EnhancedCommandHandler())
        try:
            handler.run()
        except KeyboardInterrupt:
            print("Enhanced bridge shutting down", file=sys.stderr)
        except Exception as e:
            print(f"Enhanced bridge error: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Unknown mode: {args.mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

### Phase 3: Enhanced Elixir API

Create a new API module that provides both legacy and dynamic interfaces:

**File**: `snakepit/lib/snakepit/python.ex`

```elixir
defmodule Snakepit.Python do
  @moduledoc """
  Enhanced Python interop API built on Snakepit V2 architecture.
  
  Provides universal Python method invocation while maintaining full
  backward compatibility with existing patterns. Uses the enhanced
  Python adapter to enable dynamic calls on any Python library.
  
  ## Features
  
  - Dynamic method calls on any Python object/module
  - Object persistence across calls and sessions
  - Framework-agnostic design supporting any Python library
  - Pipeline execution for complex workflows
  - Smart serialization with framework-specific optimizations
  - Full backward compatibility with existing adapters
  
  ## Usage
  
      # Configure to use enhanced adapter
      config :snakepit,
        adapter_module: Snakepit.Adapters.EnhancedPython
      
      # Dynamic method calls
      Snakepit.Python.call("pandas.read_csv", %{filepath: "data.csv"})
      Snakepit.Python.call("sklearn.linear_model.LinearRegression", %{}, store_as: "model")
      Snakepit.Python.call("stored.model.fit", %{X: data, y: labels})
      
      # Pipeline execution
      Snakepit.Python.pipeline([
        {:call, "dspy.configure", %{lm: "openai/gpt-3.5-turbo"}},
        {:call, "dspy.Predict", %{signature: "question -> answer"}, store_as: "qa"},
        {:call, "stored.qa.__call__", %{question: "What is Python?"}}
      ])
  """
  
  @doc """
  Call any Python method dynamically.
  
  ## Parameters
  
  - `target` - Python target to call (e.g., "pandas.read_csv", "stored.model.predict")
  - `kwargs` - Keyword arguments for the call (optional)
  - `opts` - Additional options including `:store_as`, `:args`, `:pool`, etc.
  
  ## Examples
  
      # Module functions
      Snakepit.Python.call("numpy.array", %{object: [1, 2, 3, 4]})
      
      # Class instantiation
      Snakepit.Python.call("sklearn.ensemble.RandomForestClassifier", %{
        n_estimators: 100
      }, store_as: "classifier")
      
      # Method calls on stored objects
      Snakepit.Python.call("stored.classifier.fit", %{X: training_data, y: labels})
      
      # DSPy integration
      Snakepit.Python.call("dspy.ChainOfThought", %{
        signature: "context, question -> reasoning, answer"
      }, store_as: "cot_program")
  """
  def call(target, kwargs \\ %{}, opts \\ []) do
    args = %{
      target: target,
      kwargs: kwargs
    }
    
    # Add optional arguments
    args = if opts[:args], do: Map.put(args, :args, opts[:args]), else: args
    args = if opts[:store_as], do: Map.put(args, :store_as, opts[:store_as]), else: args
    
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("call", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "call", args, pool_opts)
    end
  end
  
  @doc """
  Store an object for later retrieval.
  """
  def store(id, value, opts \\ []) do
    args = %{id: id, value: value}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("store", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "store", args, pool_opts)
    end
  end
  
  @doc """
  Retrieve a stored object.
  """
  def retrieve(id, opts \\ []) do
    args = %{id: id}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("retrieve", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "retrieve", args, pool_opts)
    end
  end
  
  @doc """
  List all stored objects.
  """
  def list_stored(opts \\ []) do
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("list_stored", %{}, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "list_stored", %{}, pool_opts)
    end
  end
  
  @doc """
  Delete a stored object.
  """
  def delete_stored(id, opts \\ []) do
    args = %{id: id}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("delete_stored", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "delete_stored", args, pool_opts)
    end
  end
  
  @doc """
  Execute a sequence of calls in a pipeline.
  
  ## Examples
  
      Snakepit.Python.pipeline([
        {:call, "pandas.read_csv", %{filepath: "data.csv"}, store_as: "df"},
        {:call, "stored.df.describe", %{}},
        {:call, "sklearn.preprocessing.StandardScaler", %{}, store_as: "scaler"},
        {:call, "stored.scaler.fit_transform", %{X: "stored.df"}}
      ])
      
      # With session affinity
      Snakepit.Python.pipeline([
        {:call, "dspy.configure", %{lm: "openai/gpt-3.5-turbo"}},
        {:call, "dspy.Predict", %{signature: "question -> answer"}, store_as: "qa"},
        {:call, "stored.qa.__call__", %{question: "Hello?"}}
      ], session_id: "my_session")
  """
  def pipeline(steps, opts \\ []) do
    # Convert steps to the format expected by the Python bridge
    formatted_steps = Enum.map(steps, fn
      {:call, target, kwargs} ->
        %{target: target, kwargs: kwargs}
      {:call, target, kwargs, step_opts} ->
        %{target: target, kwargs: kwargs}
        |> Map.merge(Map.new(step_opts))
    end)
    
    args = %{steps: formatted_steps}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("pipeline", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "pipeline", args, pool_opts)
    end
  end
  
  @doc """
  Inspect Python objects and get metadata.
  
  ## Examples
  
      Snakepit.Python.inspect("numpy.array")
      Snakepit.Python.inspect("stored.my_model")
  """
  def inspect(target, opts \\ []) do
    args = %{target: target}
    pool_opts = Keyword.take(opts, [:pool, :timeout, :session_id])
    
    case opts[:session_id] do
      nil -> Snakepit.execute("inspect", args, pool_opts)
      session_id -> Snakepit.execute_in_session(session_id, "inspect", args, pool_opts)
    end
  end
  
  @doc """
  Configure a Python framework with framework-specific optimizations.
  
  ## Examples
  
      # DSPy with Gemini
      Snakepit.Python.configure("dspy", %{
        provider: "google",
        model: "gemini-2.0-flash-exp", 
        api_key: System.get_env("GEMINI_API_KEY")
      })
      
      # Generic framework configuration
      Snakepit.Python.configure("transformers", %{
        model_cache_dir: "/tmp/models"
      })
  """
  def configure(framework, config, opts \\ []) do
    call("#{framework}.configure", config, opts)
  end
  
  @doc """
  Create a session-scoped context for related operations.
  
  Returns a session ID that can be used for session-affinity calls.
  All objects stored within a session are automatically cleaned up
  when the session expires.
  
  ## Examples
  
      session_id = Snakepit.Python.create_session()
      
      Snakepit.Python.call("dspy.configure", %{...}, session_id: session_id)
      Snakepit.Python.call("dspy.Predict", %{...}, store_as: "qa", session_id: session_id)
      Snakepit.Python.call("stored.qa.__call__", %{...}, session_id: session_id)
  """
  def create_session(opts \\ []) do
    session_id = "python_session_#{System.unique_integer([:positive])}"
    
    # Initialize session with a ping to ensure worker assignment
    case call("ping", %{}, [session_id: session_id] ++ opts) do
      {:ok, _} -> session_id
      {:error, reason} -> {:error, reason}
    end
  end
  
  @doc """
  Get enhanced bridge information and capabilities.
  """
  def info(opts \\ []) do
    pool_opts = Keyword.take(opts, [:pool, :timeout])
    Snakepit.execute("ping", %{}, pool_opts)
  end
end
```

## Benefits of This Extension Design

### 1. **Strict OCP Adherence**
- **Closed for Modification**: Zero changes to existing V2 bridge code
- **Open for Extension**: New capabilities through well-defined extension points
- **Backward Compatible**: All existing adapters and functionality preserved

### 2. **Universal Python Interop**
```elixir
# Any Python library becomes immediately available
Snakepit.Python.call("requests.get", %{url: "https://api.example.com"})
Snakepit.Python.call("PIL.Image.open", %{fp: "image.jpg"})
Snakepit.Python.call("torch.nn.Linear", %{in_features: 784, out_features: 10})
```

### 3. **Framework-Agnostic Design**
- **Plugin System**: Easy addition of framework-specific optimizations
- **Auto-Discovery**: Frameworks automatically detected and loaded
- **Smart Serialization**: Framework-aware result processing

### 4. **Advanced Capabilities**
- **Object Persistence**: Store complex objects across calls
- **Pipeline Execution**: Chain multiple operations seamlessly
- **Session Affinity**: Maintain state continuity within sessions
- **Inspection Tools**: Explore Python objects dynamically

### 5. **Production Ready**
- **Leverages V2 Infrastructure**: Concurrent initialization, monitoring, error handling
- **Multiple Deployment Modes**: Development, package, and production deployment
- **Comprehensive Error Handling**: Graceful degradation and detailed error reporting

## Migration Strategy

### Phase 1: Extension Deployment (Week 1-2)
1. Deploy enhanced adapter alongside existing implementations
2. No changes to existing configurations or code
3. Existing DSPy functionality continues unchanged
4. Enhanced capabilities available through new adapter

### Phase 2: Enhanced API Introduction (Week 3-4)
1. Introduce `Snakepit.Python` module
2. Provide migration examples and documentation
3. Enhanced adapter becomes available as alternative
4. Existing adapters remain fully functional

### Phase 3: Framework Plugins (Week 5-6)
1. Add plugin system for framework-specific optimizations
2. Implement additional framework plugins (Transformers, etc.)
3. Optimize performance based on usage patterns
4. Expand documentation and examples

### Phase 4: Ecosystem Growth (Week 7+)
1. Community contribution of additional plugins
2. Domain-specific helper libraries
3. Performance optimizations based on real-world usage
4. Integration with monitoring and observability tools

## Usage Examples

### Data Science Workflow
```elixir
session_id = Snakepit.Python.create_session()

Snakepit.Python.pipeline([
  {:call, "pandas.read_csv", %{filepath: "data.csv"}, store_as: "df"},
  {:call, "stored.df.dropna", %{}, store_as: "clean_df"},
  {:call, "sklearn.model_selection.train_test_split", %{
    X: "stored.clean_df", 
    test_size: 0.2
  }, store_as: "split_data"},
  {:call, "sklearn.ensemble.RandomForestRegressor", %{}, store_as: "model"},
  {:call, "stored.model.fit", %{X: "train_X", y: "train_y"}}
], session_id: session_id)
```

### Multi-Framework ML Pipeline
```elixir
session_id = Snakepit.Python.create_session()

# Use DSPy for text processing
Snakepit.Python.call("dspy.configure", %{
  lm: "openai/gpt-3.5-turbo",
  api_key: System.get_env("OPENAI_API_KEY")
}, session_id: session_id)

Snakepit.Python.call("dspy.Predict", %{
  signature: "text -> summary"
}, store_as: "summarizer", session_id: session_id)

# Use Transformers for sentiment analysis
Snakepit.Python.call("transformers.pipeline", %{
  task: "sentiment-analysis"
}, store_as: "sentiment", session_id: session_id)

# Process data through both models
text = "Long article text here..."

{:ok, summary} = Snakepit.Python.call("stored.summarizer.__call__", %{
  text: text
}, session_id: session_id)

{:ok, sentiment} = Snakepit.Python.call("stored.sentiment.__call__", %{
  text: text
}, session_id: session_id)
```

### Legacy Compatibility
```elixir
# Existing DSPy code continues to work unchanged
{:ok, _} = SnakepitDspy.create_qa_program("my_qa", "Answer accurately")
{:ok, answer} = SnakepitDspy.ask_question("my_qa", "What is Elixir?")

# Can be used alongside enhanced capabilities
Snakepit.Python.call("stored.my_qa.__call__", %{
  question: "What are the benefits of functional programming?"
})
```

## Conclusion

This extension design achieves the goals of universal Python interop and enhanced bridge capabilities while strictly adhering to the Open-Closed Principle. By leveraging the excellent extension points provided by the V2 bridge architecture, we can add powerful dynamic capabilities without modifying any existing code.

The result is a production-ready enhancement that:

1. **Preserves all existing functionality** - Zero breaking changes
2. **Adds universal Python interop** - Any Python library becomes accessible  
3. **Maintains architectural integrity** - Clean separation of concerns
4. **Enables ecosystem growth** - Framework plugins and community contributions
5. **Provides migration path** - Gradual adoption without disruption

The V2 bridge's excellent design makes this enhancement possible through extension rather than modification, demonstrating the power of well-architected software that truly follows OCP principles.