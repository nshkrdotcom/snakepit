"""
Base adapter class for Snakepit Python adapters.

Provides tool discovery and registration functionality that all adapters should inherit from.
"""

import inspect
from typing import List, Dict, Any, Callable, Optional
from dataclasses import dataclass
import logging

from snakepit_bridge_pb2 import ToolRegistration, ParameterSpec
import snakepit_bridge_pb2 as pb2

logger = logging.getLogger(__name__)


@dataclass
class ToolMetadata:
    """Metadata for a tool function."""
    description: str = ""
    supports_streaming: bool = False
    parameters: List[Dict[str, Any]] = None
    required_variables: List[str] = None
    
    def __post_init__(self):
        if self.parameters is None:
            self.parameters = []
        if self.required_variables is None:
            self.required_variables = []


def tool(description: str = "", 
         supports_streaming: bool = False,
         required_variables: List[str] = None):
    """
    Decorator to mark a method as a tool and attach metadata.
    
    Example:
        @tool(description="Search for items", supports_streaming=True)
        def search(self, query: str, limit: int = 10):
            return search_results
    """
    def decorator(func):
        metadata = ToolMetadata(
            description=description or func.__doc__ or "",
            supports_streaming=supports_streaming,
            required_variables=required_variables or []
        )
        func._tool_metadata = metadata
        return func
    return decorator


class BaseAdapter:
    """Base class for all Snakepit Python adapters."""
    
    def __init__(self):
        self._tools_cache = None
        
    def get_tools(self) -> List[ToolRegistration]:
        """
        Discover and return tool specifications for all tools in this adapter.
        
        Returns:
            List of ToolRegistration protobuf messages
        """
        if self._tools_cache is not None:
            return self._tools_cache
            
        tools = []
        
        # Discover all methods marked with @tool decorator
        for name, method in inspect.getmembers(self, inspect.ismethod):
            if hasattr(method, '_tool_metadata'):
                tool_reg = self._create_tool_registration(name, method)
                tools.append(tool_reg)
        
        # Also discover execute_tool methods for backward compatibility
        if hasattr(self, 'execute_tool') and not any(t.name == 'execute_tool' for t in tools):
            # Legacy support - treat execute_tool as a tool if not decorated
            tool_reg = ToolRegistration(
                name='execute_tool',
                description='Legacy tool execution method',
                supports_streaming=False,
                parameters=[],
                metadata={}
            )
            tools.append(tool_reg)
        
        self._tools_cache = tools
        return tools
    
    def _create_tool_registration(self, name: str, method: Callable) -> ToolRegistration:
        """Create a ToolRegistration from a method and its metadata."""
        metadata = getattr(method, '_tool_metadata', ToolMetadata())
        
        # Extract parameters from function signature
        sig = inspect.signature(method)
        parameters = []
        
        for param_name, param in sig.parameters.items():
            if param_name == 'self':
                continue
                
            param_spec = self._create_parameter_spec(param_name, param)
            parameters.append(param_spec)
        
        # Create metadata dict
        tool_metadata = {
            'adapter_class': self.__class__.__name__,
            'module': self.__class__.__module__,
        }
        
        if metadata.required_variables:
            tool_metadata['required_variables'] = ','.join(metadata.required_variables)
        
        return ToolRegistration(
            name=name,
            description=metadata.description,
            parameters=parameters,
            supports_streaming=metadata.supports_streaming,
            metadata=tool_metadata
        )
    
    def _create_parameter_spec(self, name: str, param: inspect.Parameter) -> ParameterSpec:
        """Create a ParameterSpec from a function parameter."""
        # Determine type from annotation
        param_type = 'any'
        if param.annotation != inspect.Parameter.empty:
            type_name = getattr(param.annotation, '__name__', str(param.annotation))
            param_type = type_name.lower()
        
        # Check if required
        required = param.default == inspect.Parameter.empty
        
        # Create parameter spec
        param_spec = ParameterSpec(
            name=name,
            type=param_type,
            description="",  # Could be enhanced with docstring parsing
            required=required
        )
        
        # Set default value if present
        if param.default != inspect.Parameter.empty:
            # For now, store defaults as JSON in validation_json
            # In a full implementation, we'd properly serialize to Any
            import json
            param_spec.validation_json = json.dumps({
                'default': param.default
            })
        
        return param_spec
    
    def call_tool(self, tool_name: str, **kwargs) -> Any:
        """
        Call a tool by name with the given parameters.
        
        This is used internally by the framework to dispatch tool calls.
        """
        if not hasattr(self, tool_name):
            raise AttributeError(f"Tool '{tool_name}' not found in {self.__class__.__name__}")
        
        method = getattr(self, tool_name)
        if not callable(method):
            raise TypeError(f"'{tool_name}' is not a callable tool")
        
        return method(**kwargs)
    
    def register_with_session(self, session_id: str, stub) -> List[str]:
        """
        Register all tools from this adapter with the Elixir session.
        
        Args:
            session_id: The session ID to register tools with
            stub: The gRPC stub to use for registration
            
        Returns:
            List of registered tool names
        """
        tools = self.get_tools()
        
        if not tools:
            logger.warning(f"No tools found in adapter {self.__class__.__name__}")
            return []
        
        # Create registration request
        request = pb2.RegisterToolsRequest(
            session_id=session_id,
            tools=tools,
            worker_id=f"python-{id(self)}"  # Use object ID as worker ID
        )
        
        try:
            response = stub.RegisterTools(request)
            if response.success:
                logger.info(f"Registered {len(tools)} tools for session {session_id}")
                return list(response.tool_ids.keys())
            else:
                logger.error(f"Failed to register tools: {response.error_message}")
                return []
        except Exception as e:
            logger.error(f"Error registering tools: {e}")
            return []