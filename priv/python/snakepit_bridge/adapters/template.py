"""
⚠️  WARNING: This is a TEMPLATE adapter, not a functional implementation!

This adapter provides the minimal structure needed to create custom Snakepit adapters.
It does NOT implement execute_tool() or any actual functionality.

For a working reference implementation, see ShowcaseAdapter at:
  snakepit_bridge/adapters/showcase/showcase_adapter.py

To create a custom adapter:
1. Copy this file to your_adapter.py
2. Rename TemplateAdapter to YourAdapter
3. Implement execute_tool() method
4. Add your custom logic
5. Configure via pool_config.adapter_args

This is intentionally minimal to serve as a clean starting point.
"""

from typing import Any, Dict, Optional

from snakepit_bridge.logging_config import get_logger

logger = get_logger(__name__)


class TemplateAdapter:
    """
    Template adapter for creating custom Snakepit adapters.

    ⚠️  This is a TEMPLATE - it does NOT work out of the box!

    You MUST implement execute_tool() and any other methods your
    application needs. See ShowcaseAdapter for a complete example.
    """

    def __init__(self):
        self.session_context = None
        self.initialized = False

    def set_session_context(self, session_context):
        """Set the session context for this adapter instance."""
        self.session_context = session_context
        if hasattr(session_context, 'session_id'):
            logger.info(f"Session context set: {session_context.session_id}")

    async def initialize(self):
        """
        Initialize the adapter with any necessary setup.

        Override this to:
        - Register tools
        - Set up ML frameworks
        - Initialize connections
        """
        self.initialized = True
        if self.session_context and hasattr(self.session_context, 'session_id'):
            logger.info(f"Adapter initialized for session: {self.session_context.session_id}")
        else:
            logger.info("Adapter initialized")

    async def cleanup(self):
        """
        Clean up adapter resources.

        Override this to clean up connections, models, etc.
        """
        if self.session_context:
            logger.info(f"Cleaning up adapter for session: {self.session_context.session_id}")

        self.initialized = False

    def get_info(self) -> Dict[str, Any]:
        """Get adapter information."""
        return {
            "adapter": "TemplateAdapter",
            "version": "0.1.0",
            "template": True,  # Indicates this is not a functional adapter
            "initialized": self.initialized,
            "session_id": self.session_context.session_id if self.session_context else None,
            "warning": "This is a template - implement execute_tool() for functionality",
            "reference": "See ShowcaseAdapter for complete implementation"
        }

    # ⚠️  YOU MUST IMPLEMENT THIS METHOD
    def execute_tool(self, tool_name: str, arguments: Dict[str, Any], context) -> Any:
        """
        Execute a tool by name.

        ⚠️  NOT IMPLEMENTED - This is a template!

        Override this method to handle your tools:

        Example:
            def execute_tool(self, tool_name, arguments, context):
                if tool_name == "my_custom_tool":
                    return {"result": self._my_custom_logic(arguments)}
                raise NotImplementedError(f"Unknown tool: {tool_name}")
        """
        raise NotImplementedError(
            f"TemplateAdapter does not implement tools. "
            f"This is a template - you must implement execute_tool(). "
            f"See ShowcaseAdapter for a complete example."
        )
