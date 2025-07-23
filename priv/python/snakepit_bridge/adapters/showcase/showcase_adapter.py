"""
Refactored ShowcaseAdapter that delegates to specialized handlers.

This adapter demonstrates best practices for Snakepit adapters:
1. All state is managed through SessionContext (Elixir's SessionStore)
2. Code is organized into domain-specific handlers
3. Python workers remain stateless for better scalability
"""

from typing import Dict, Any
from snakepit_bridge import SessionContext
from .handlers import (
    BasicOpsHandler,
    SessionOpsHandler,
    BinaryOpsHandler,
    StreamingOpsHandler,
    ConcurrentOpsHandler,
    VariableOpsHandler,
    MLWorkflowHandler
)


class ShowcaseAdapter:
    """Main adapter demonstrating Snakepit features through specialized handlers."""
    
    def __init__(self):
        # Initialize handlers
        self.handlers = {
            'basic': BasicOpsHandler(),
            'session': SessionOpsHandler(),
            'binary': BinaryOpsHandler(),
            'streaming': StreamingOpsHandler(),
            'concurrent': ConcurrentOpsHandler(),
            'variable': VariableOpsHandler(),
            'ml': MLWorkflowHandler()
        }
        
        # Build tool registry from all handlers
        self.tools = {}
        for handler in self.handlers.values():
            self.tools.update(handler.get_tools())
    
    def set_session_context(self, session_context):
        """Set the session context for this adapter instance."""
        self.session_context = session_context
    
    def execute_tool(self, tool_name: str, arguments: Dict[str, Any], context) -> Any:
        """Execute a tool by name with given arguments."""
        if tool_name in self.tools:
            tool = self.tools[tool_name]
            return tool.func(context, **arguments)
        else:
            raise ValueError(f"Unknown tool: {tool_name}")