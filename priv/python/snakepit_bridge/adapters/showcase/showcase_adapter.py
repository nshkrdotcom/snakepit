"""
Refactored ShowcaseAdapter that delegates to specialized handlers.

This adapter demonstrates best practices for Snakepit adapters:
1. All state is managed through SessionContext (Elixir's SessionStore)
2. Code is organized into domain-specific handlers
3. Python workers remain stateless for better scalability
"""

from typing import Dict, Any
from snakepit_bridge import SessionContext
from snakepit_bridge.base_adapter import BaseAdapter, tool
from .handlers import (
    BasicOpsHandler,
    SessionOpsHandler,
    BinaryOpsHandler,
    StreamingOpsHandler,
    ConcurrentOpsHandler,
    MLWorkflowHandler
)


class ShowcaseAdapter(BaseAdapter):
    """Main adapter demonstrating Snakepit features through specialized handlers."""
    
    def __init__(self):
        super().__init__()
        
        # Initialize handlers
        self.handlers = {
            'basic': BasicOpsHandler(),
            'session': SessionOpsHandler(),
            'binary': BinaryOpsHandler(),
            'streaming': StreamingOpsHandler(),
            'concurrent': ConcurrentOpsHandler(),
            'ml': MLWorkflowHandler()
        }
        
        # Build tool registry from all handlers
        self._handler_tools = {}
        for handler in self.handlers.values():
            self._handler_tools.update(handler.get_tools())
        
        # Session context will be set by the framework
        self.session_context = None
    
    def set_session_context(self, session_context):
        """Set the session context for this adapter instance."""
        self.session_context = session_context
    
    # Legacy method for backward compatibility
    def execute_tool(self, tool_name: str, arguments: Dict[str, Any], context) -> Any:
        """Execute a tool by name with given arguments (legacy support)."""
        if tool_name in self._handler_tools:
            tool = self._handler_tools[tool_name]
            return tool.func(context, **arguments)
        else:
            # Try the new tool system
            return self.call_tool(tool_name, **arguments)
    
    # Expose key handler methods as tools using the decorator
    
    @tool(description="Get adapter information and capabilities")
    def adapter_info(self) -> Dict[str, Any]:
        """Return information about the adapter capabilities."""
        return self.handlers['basic'].get_tools()['adapter_info'].func(self.session_context)
    
    @tool(description="Echo back provided arguments")
    def echo(self, **kwargs) -> Dict[str, Any]:
        """Echo back all provided arguments."""
        return self.handlers['basic'].get_tools()['echo'].func(self.session_context, **kwargs)
    
    @tool(description="Execute basic operations like echo and add")
    def basic_echo(self, message: str) -> str:
        """Echo a message back."""
        return self.handlers['basic'].get_tools()['echo'].func(self.session_context, message=message)
    
    @tool(description="Add two numbers")
    def basic_add(self, a: float, b: float) -> float:
        """Add two numbers together."""
        return self.handlers['basic'].get_tools()['add'].func(self.session_context, a=a, b=b)
    
    @tool(description="Process text with various operations")
    def process_text(self, text: str, operation: str = "upper") -> Dict[str, Any]:
        """Process text with specified operation (upper, lower, reverse, length)."""
        operations = {
            "upper": lambda t: t.upper(),
            "lower": lambda t: t.lower(), 
            "reverse": lambda t: t[::-1],
            "length": lambda t: len(t)
        }
        
        if operation in operations:
            result = operations[operation](text)
            return {
                "original": text,
                "operation": operation,
                "result": result,
                "success": True
            }
        else:
            return {
                "original": text,
                "operation": operation,
                "error": f"Unknown operation: {operation}",
                "available_operations": list(operations.keys()),
                "success": False
            }
    
    @tool(description="Get basic statistics and system information")
    def get_stats(self) -> Dict[str, Any]:
        """Return basic statistics about the adapter and system."""
        import time
        import psutil
        import os
        
        return {
            "adapter": {
                "name": "ShowcaseAdapter",
                "version": "2.0.0",
                "registered_tools": len([m for m in dir(self) if hasattr(getattr(self, m), '_tool_metadata')]),
                "session_id": self.session_context.session_id if self.session_context else None
            },
            "system": {
                "timestamp": time.time(),
                "pid": os.getpid(),
                "memory_usage_mb": round(psutil.Process().memory_info().rss / 1024 / 1024, 2),
                "cpu_percent": psutil.cpu_percent(interval=0.1)
            },
            "success": True
        }
    
    @tool(description="Perform text analysis using ML")
    def ml_analyze_text(self, text: str) -> Dict[str, Any]:
        """Analyze text using machine learning."""
        return self.handlers['ml'].get_tools()['analyze_text'].func(self.session_context, text=text)
    
    @tool(description="Process binary data", supports_streaming=False)
    def process_binary(self, data: bytes, operation: str = 'checksum') -> Any:
        """Process binary data with specified operation."""
        return self.handlers['binary'].get_tools()['process_binary'].func(
            self.session_context, 
            data=data, 
            operation=operation
        )
    
    @tool(description="Stream data in chunks", supports_streaming=True)
    def stream_data(self, count: int = 5, delay: float = 1.0):
        """Stream data chunks with optional delay."""
        handler_tool = self.handlers['streaming'].get_tools()['stream_data']
        # This returns a generator for streaming
        return handler_tool.func(self.session_context, count=count, delay=delay)
    
    @tool(description="Execute concurrent tasks")
    def concurrent_demo(self, task_count: int = 3) -> Dict[str, Any]:
        """Execute multiple tasks concurrently."""
        return self.handlers['concurrent'].get_tools()['concurrent_demo'].func(
            self.session_context,
            task_count=task_count
        )
    
    @tool(description="Demonstrate integration with Elixir tools", 
          required_variables=["elixir_tools_enabled"])
    def call_elixir_demo(self, tool_name: str, **kwargs) -> Any:
        """
        Demonstrate calling an Elixir tool from Python.
        
        This showcases the bidirectional tool bridge where Python
        can seamlessly call tools implemented in Elixir.
        """
        if not self.session_context:
            raise RuntimeError("Session context not initialized")
        
        # Check if Elixir tools are available
        if tool_name in self.session_context.elixir_tools:
            result = self.session_context.call_elixir_tool(tool_name, **kwargs)
            return {
                'tool': tool_name,
                'result': result,
                'source': 'elixir',
                'message': f'Successfully called Elixir tool: {tool_name}'
            }
        else:
            available = list(self.session_context.elixir_tools.keys())
            return {
                'error': f'Elixir tool {tool_name} not found',
                'available_tools': available,
                'hint': 'Make sure the tool is registered in Elixir with exposed_to_python: true'
            }