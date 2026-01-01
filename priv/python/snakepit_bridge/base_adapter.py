"""
Base adapter class for Snakepit Python adapters.

Provides tool discovery and registration functionality that all adapters should inherit from.

Adapter Lifecycle
-----------------
Adapters follow a **per-request lifecycle**:

1. A new adapter instance is created for each incoming RPC request
2. `initialize()` is called (if defined) at the start of each request
3. The tool is executed via `execute_tool()` or a decorated method
4. `cleanup()` is called (if defined) at the end of each request, even on error

This means:
- Do NOT rely on adapter instance state persisting across requests
- Use module-level caches or external stores for shared state (e.g., loaded models)
- Both `initialize()` and `cleanup()` can be sync or async

Example with model caching::

    # Module-level cache (shared across requests)
    _model_cache = {}

    class MyAdapter(BaseAdapter):
        def initialize(self):
            # Load model from cache or disk
            if "model" not in _model_cache:
                _model_cache["model"] = load_expensive_model()
            self.model = _model_cache["model"]

        def cleanup(self):
            # Optional: release request-specific resources
            pass

        @tool(description="Run inference")
        def predict(self, input_data: str) -> dict:
            return self.model.predict(input_data)

For thread-safe adapters (used with grpc_server_threaded.py), also set:
    __thread_safe__ = True
"""

import inspect
from typing import List, Dict, Any, Callable, Optional
from dataclasses import dataclass
import asyncio

from snakepit_bridge_pb2 import ToolRegistration, ParameterSpec
import snakepit_bridge_pb2 as pb2
from snakepit_bridge.logging_config import get_logger

logger = get_logger(__name__)


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
        self._session_context = None

    @property
    def session_id(self) -> Optional[str]:
        """
        Get the session ID from the current context.

        This is the authoritative session_id for this request.
        Use this for any session-scoped operations.

        Returns:
            Session ID string or None if no context is set
        """
        ctx = getattr(self, 'session_context', None) or self._session_context
        if ctx:
            return ctx.session_id
        return None

    def set_session_context(self, session_context) -> None:
        """
        Set the session context for this adapter instance.

        This is called by the gRPC server before tool execution.
        The session_id from this context is the authoritative session
        identifier for routing and ref storage.

        Subclasses may override this, but should call super().set_session_context()
        or set self.session_context = session_context.

        Args:
            session_context: SessionContext instance with session_id and stub
        """
        self._session_context = session_context
        # Also set as attribute for backward compatibility with adapters that
        # use self.session_context = context in their __init__ or elsewhere
        self.session_context = session_context

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
        Register adapter tools with the Elixir session (synchronous helpers).

        Use this variant when calling from synchronous contexts. For asyncio-based
        adapters or aio stubs, call `await register_with_session_async(...)` instead
        so the event loop is never blocked.

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
            raw_response = stub.RegisterTools(request)
            response = self._coerce_stub_response(raw_response)
            if response.success:
                logger.info(f"Registered {len(tools)} tools for session {session_id}")
                return list(response.tool_ids.keys())

            error_message = response.error_message or ""
            if "duplicate_tool" in error_message:
                logger.info(
                    "Tools already registered for session %s; skipping duplicate registration.",
                    session_id,
                )
                return [tool.name for tool in tools]

            logger.error(f"Failed to register tools: {response.error_message}")
            return []
        except Exception as e:
            logger.error(f"Error registering tools: {e}")
            return []

    async def register_with_session_async(self, session_id: str, stub) -> List[str]:
        """
        Async variant of register_with_session for asyncio-based stubs/adapters.

        This helper never blocks the running event loop: native awaitables are awaited,
        and blocking UnaryUnaryCall/callable responses run inside the default executor.

        Args:
            session_id: The session ID to register tools with
            stub: The (possibly-async) gRPC stub to use for registration

        Returns:
            List of registered tool names
        """
        tools = self.get_tools()

        if not tools:
            logger.warning(f"No tools found in adapter {self.__class__.__name__}")
            return []

        request = pb2.RegisterToolsRequest(
            session_id=session_id,
            tools=tools,
            worker_id=f"python-{id(self)}"
        )

        try:
            raw_response = stub.RegisterTools(request)
            response = await self._await_stub_response(raw_response)

            if response.success:
                logger.info(f"Registered {len(tools)} tools for session {session_id}")
                return list(response.tool_ids.keys())

            error_message = response.error_message or ""
            if "duplicate_tool" in error_message:
                logger.info(
                    "Tools already registered for session %s; skipping duplicate registration.",
                    session_id,
                )
                return [tool.name for tool in tools]

            logger.error(f"Failed to register tools: {response.error_message}")
            return []
        except Exception as e:
            logger.error(f"Error registering tools (async): {e}")
            return []

    def _coerce_stub_response(self, response):
        """
        Handle the different response shapes returned by gRPC stubs.

        gRPC Python may return:
        - Plain protobuf responses
        - UnaryUnaryCall objects with .result()
        - Awaitable coroutines (aio stubs)
        - Callables that lazily fetch the result
        """
        if inspect.isawaitable(response):
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                return asyncio.run(response)

            raise RuntimeError(
                "Cannot synchronously wait for an async RegisterTools response while an event "
                "loop is already running. Call register_with_session from synchronous code or "
                "await the stub response yourself before invoking this helper."
            )

        result_attr = getattr(response, "result", None)
        if callable(result_attr):
            return result_attr()

        if callable(response):
            return response()

        return response

    async def _await_stub_response(self, response):
        """
        Await the different response shapes returned by gRPC stubs without blocking.
        """
        if inspect.isawaitable(response):
            return await response

        result_attr = getattr(response, "result", None)
        if callable(result_attr):
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(None, result_attr)

        if callable(response):
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(None, response)

        return response
