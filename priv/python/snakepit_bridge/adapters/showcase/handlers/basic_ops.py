"""Basic operations handler for showcase adapter."""

import time
from typing import Dict, Any
from datetime import datetime
from ..tool import Tool


class BasicOpsHandler:
    """Handler for basic operations like ping, echo, and error demonstrations."""
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "ping": Tool(self.ping),
            "echo": Tool(self.echo),
            "error_demo": Tool(self.error_demo),
            "adapter_info": Tool(self.adapter_info),
        }
    
    def ping(self, ctx, message: str = "pong") -> Dict[str, str]:
        """Simple ping operation."""
        return {"message": message, "timestamp": str(time.time())}
    
    def echo(self, ctx, **kwargs) -> Dict[str, Any]:
        """Echo back all provided arguments."""
        return {"echoed": kwargs}
    
    def error_demo(self, ctx, error_type: str = "generic") -> None:
        """Demonstrate error handling with different error types."""
        if error_type == "value":
            raise ValueError("This is a demonstration ValueError")
        elif error_type == "runtime":
            raise RuntimeError("This is a demonstration RuntimeError")
        else:
            raise Exception("This is a generic exception")
    
    def adapter_info(self, ctx) -> Dict[str, Any]:
        """Return information about the adapter capabilities."""
        return {
            "adapter_name": "ShowcaseAdapter",
            "version": "2.0.0",  # Updated version for refactored adapter
            "capabilities": [
                "binary_serialization",
                "streaming",
                "ml_workflows",
                "variables",
                "session_state_via_elixir"
            ],
            "handlers": [
                "BasicOpsHandler",
                "SessionOpsHandler",
                "BinaryOpsHandler",
                "StreamingOpsHandler",
                "ConcurrentOpsHandler",
                "VariableOpsHandler",
                "MLWorkflowHandler"
            ]
        }