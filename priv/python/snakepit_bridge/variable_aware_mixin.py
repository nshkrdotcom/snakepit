"""
VariableAwareMixin for DSPy integration.
Provides variable management capabilities to DSPy modules.
"""

from typing import Any, Dict, Optional, Callable
import grpc
from . import snakepit_bridge_pb2
from . import snakepit_bridge_pb2_grpc
from .serialization import TypeSerializer


class VariableAwareMixin:
    """
    Mixin to make DSPy modules aware of the variable system.
    
    This will be used in Stage 2 to integrate variable management
    into DSPy signatures and modules.
    """
    
    def __init__(self, channel: grpc.Channel, session_id: str):
        """Initialize the mixin with gRPC channel and session."""
        self._channel = channel
        self._session_id = session_id
        self._stub = snakepit_bridge_pb2_grpc.SnakepitBridgeStub(channel)
        self._watchers = {}
        
    def get_variable(self, name: str) -> Any:
        """Get a variable by name."""
        request = snakepit_bridge_pb2.GetVariableRequest(
            session_id=self._session_id,
            name=name
        )
        
        try:
            response = self._stub.GetVariable(request)
            if response.variable:
                return TypeSerializer.decode_any(response.variable.value)
            return None
        except grpc.RpcError as e:
            raise RuntimeError(f"Failed to get variable {name}: {e.details()}")
    
    def set_variable(self, name: str, value: Any, metadata: Optional[Dict] = None) -> None:
        """Set a variable value."""
        # Infer type from value
        var_type = self._infer_type(value)
        
        # Encode value
        any_value = TypeSerializer.encode_any(value, var_type)
        
        request = snakepit_bridge_pb2.SetVariableRequest(
            session_id=self._session_id,
            name=name,
            value=any_value,
            metadata=metadata or {}
        )
        
        try:
            self._stub.SetVariable(request)
        except grpc.RpcError as e:
            raise RuntimeError(f"Failed to set variable {name}: {e.details()}")
    
    def register_variable(self, name: str, var_type: str, initial_value: Any,
                         constraints: Optional[Dict] = None,
                         metadata: Optional[Dict] = None) -> str:
        """Register a new variable."""
        # Encode value
        any_value = TypeSerializer.encode_any(initial_value, var_type)
        
        # Encode constraints
        constraints_json = ""
        if constraints:
            import json
            constraints_json = json.dumps(constraints)
        
        request = snakepit_bridge_pb2.RegisterVariableRequest(
            session_id=self._session_id,
            name=name,
            type=var_type,
            initial_value=any_value,
            constraints=constraints_json,
            metadata=metadata or {}
        )
        
        try:
            response = self._stub.RegisterVariable(request)
            return response.variable_id
        except grpc.RpcError as e:
            raise RuntimeError(f"Failed to register variable {name}: {e.details()}")
    
    def watch_variable(self, name: str, callback: Callable[[str, Any, Any, Dict], None]) -> None:
        """
        Watch a variable for changes.
        
        callback receives: (name, old_value, new_value, metadata)
        """
        # Implementation will be completed in Stage 1 with streaming support
        self._watchers[name] = callback
        
    def _infer_type(self, value: Any) -> str:
        """Infer variable type from Python value."""
        if isinstance(value, bool):
            return "boolean"
        elif isinstance(value, int):
            return "integer"
        elif isinstance(value, float):
            return "float"
        elif isinstance(value, str):
            return "string"
        elif isinstance(value, list) and all(isinstance(x, (int, float)) for x in value):
            return "embedding"
        elif isinstance(value, dict) and "shape" in value and "data" in value:
            return "tensor"
        else:
            return "string"  # Default to string
    
    def __enter__(self):
        """Context manager support."""
        return self
        
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Cleanup on context exit."""
        # Future: close any active streams
        pass