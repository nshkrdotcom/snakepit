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
import os
import importlib
import inspect
import time
import traceback
from typing import Dict, Any, Optional, Union, List
from abc import ABC, abstractmethod

# Import V2 bridge foundation
try:
    from snakepit_bridge.core import BaseCommandHandler, ProtocolHandler
    from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression
except ImportError:
    # Fallback for development mode without package installation
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from snakepit_bridge.core import BaseCommandHandler, ProtocolHandler
    from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression


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


class TransformersPlugin(FrameworkPlugin):
    """Transformers framework plugin."""
    
    def name(self) -> str:
        return "transformers"
    
    def load(self) -> Any:
        import transformers
        return transformers
    
    def serialize_result(self, obj: Any) -> Optional[Dict[str, Any]]:
        """Transformers-specific serialization."""
        if hasattr(obj, '__class__'):
            class_name = obj.__class__.__name__
            if 'Pipeline' in class_name:
                return {
                    "type": class_name,
                    "module": "transformers",
                    "task": getattr(obj, 'task', 'unknown'),
                    "model": getattr(obj, 'model', {}).get('name_or_path', 'unknown'),
                    "string_repr": str(obj)
                }
        return None


class PandasPlugin(FrameworkPlugin):
    """Pandas framework plugin."""
    
    def name(self) -> str:
        return "pandas"
    
    def load(self) -> Any:
        import pandas
        return pandas
    
    def serialize_result(self, obj: Any) -> Optional[Dict[str, Any]]:
        """Pandas-specific serialization."""
        if hasattr(obj, '__class__'):
            class_name = obj.__class__.__name__
            if class_name == 'DataFrame':
                return {
                    "type": "DataFrame",
                    "module": "pandas",
                    "shape": obj.shape,
                    "columns": list(obj.columns),
                    "dtypes": {col: str(dtype) for col, dtype in obj.dtypes.items()},
                    "head": obj.head().to_dict(),
                    "string_repr": str(obj)
                }
            elif class_name == 'Series':
                return {
                    "type": "Series",
                    "module": "pandas",
                    "length": len(obj),
                    "dtype": str(obj.dtype),
                    "head": obj.head().to_dict(),
                    "string_repr": str(obj)
                }
        return None


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
        self.start_time = time.time()
        self.request_count = 0
        
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
            TransformersPlugin(),
            PandasPlugin(),
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
            self.request_count += 1
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
                    if hasattr(plugin, 'configure'):
                        configured = plugin.configure(kwargs)
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
                "value": [self._generic_serialize(item) for item in obj[:10]],  # Limit to first 10 items
                "length": len(obj)
            }
        
        if isinstance(obj, dict):
            # Limit dict serialization to avoid huge payloads
            items = list(obj.items())[:10]
            return {
                "type": "dict",
                "value": {k: self._generic_serialize(v) for k, v in items},
                "length": len(obj)
            }
        
        # Complex objects
        try:
            if hasattr(obj, '__dict__'):
                attrs = {}
                for key, value in list(obj.__dict__.items())[:10]:  # Limit attributes
                    if not key.startswith('_'):
                        try:
                            attrs[key] = self._generic_serialize(value)
                        except:
                            attrs[key] = {"type": "str", "value": str(value)}
                
                return {
                    "type": type(obj).__name__,
                    "module": getattr(obj.__class__, '__module__', 'unknown'),
                    "attributes": attrs,
                    "string_repr": str(obj)[:500]  # Limit string representation
                }
            else:
                return {
                    "type": type(obj).__name__,
                    "value": str(obj)[:500]  # Limit string representation
                }
        except Exception as e:
            return {
                "type": "SerializationError",
                "error": str(e),
                "string_repr": str(obj)[:500]
            }
    
    # Legacy command handlers (for backward compatibility)
    def handle_configure_lm(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy configure_lm command."""
        self.request_count += 1
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
        self.request_count += 1
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
        self.request_count += 1
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
    
    def handle_get_program(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy get_program command."""
        self.request_count += 1
        program_id = args.get("program_id")
        return self.handle_retrieve({"id": program_id})
    
    def handle_list_programs(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy list_programs command."""
        self.request_count += 1
        return self.handle_list_stored(args)
    
    def handle_delete_program(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy delete_program command."""
        self.request_count += 1
        program_id = args.get("program_id")
        return self.handle_delete_stored({"id": program_id})
    
    def handle_clear_session(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle legacy clear_session command."""
        self.request_count += 1
        self.stored_objects.clear()
        return {"status": "ok", "message": "Session cleared"}
    
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Enhanced ping with framework status."""
        self.request_count += 1
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
        self.request_count += 1
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
        self.request_count += 1
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
        self.request_count += 1
        return {
            "status": "ok",
            "stored_objects": list(self.stored_objects.keys()),
            "count": len(self.stored_objects)
        }
    
    def handle_delete_stored(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Delete a stored object."""
        self.request_count += 1
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
        self.request_count += 1
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
        self.request_count += 1
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
                "string_repr": str(obj)[:500]
            }
            
            if hasattr(obj, '__doc__') and obj.__doc__:
                inspection["docstring"] = obj.__doc__[:1000]  # Limit docstring length
            
            if callable(obj):
                try:
                    sig = inspect.signature(obj)
                    inspection["signature"] = str(sig)
                except:
                    pass
            
            if hasattr(obj, '__dict__'):
                inspection["attributes"] = list(obj.__dict__.keys())[:20]  # Limit attributes
            
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
            
            input_names = []
            for inp in inputs:
                if isinstance(inp, dict):
                    input_names.append(inp.get("name", "input"))
                elif isinstance(inp, str):
                    input_names.append(inp)
                else:
                    input_names.append("input")
            
            output_names = []
            for out in outputs:
                if isinstance(out, dict):
                    output_names.append(out.get("name", "output"))
                elif isinstance(out, str):
                    output_names.append(out)
                else:
                    output_names.append("output")
            
            input_str = ", ".join(input_names)
            output_str = ", ".join(output_names)
            
            return f"{input_str} -> {output_str}"
        
        return "input -> output"  # fallback


def main():
    """Main entry point for enhanced bridge."""
    import argparse
    import os
    
    parser = argparse.ArgumentParser(description="Enhanced Python Bridge for Snakepit V2")
    parser.add_argument("--mode", default="enhanced-worker", help="Bridge mode")
    args = parser.parse_args()
    
    if args.mode == "enhanced-worker":
        # Setup error handling
        setup_broken_pipe_suppression()
        
        # Use enhanced command handler
        command_handler = EnhancedCommandHandler()
        protocol_handler = ProtocolHandler(command_handler)
        setup_graceful_shutdown(protocol_handler)
        
        try:
            protocol_handler.run()
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