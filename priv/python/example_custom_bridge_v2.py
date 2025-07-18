#!/usr/bin/env python3
"""
Example of creating a custom bridge by extending the snakepit_bridge package.

This demonstrates how to create your own adapter without modifying
the core bridge logic, using proper package imports instead of
fragile sys.path manipulation.

This version showcases:
- Proper relative imports from the snakepit_bridge package
- Extending the generic command set with custom commands
- Production-ready error handling and graceful shutdown
"""

import sys
import os
import hashlib
import base64
from datetime import datetime

# Add the bridge package to Python path if not already installed
if __name__ == "__main__":
    bridge_dir = os.path.dirname(os.path.abspath(__file__))
    if bridge_dir not in sys.path:
        sys.path.insert(0, bridge_dir)

from snakepit_bridge import BaseCommandHandler, ProtocolHandler
from snakepit_bridge.adapters.generic import GenericCommandHandler
from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression


class CustomCommandHandler(BaseCommandHandler):
    """
    Example custom command handler that adds new functionality
    while keeping all the existing generic commands.
    """
    
    def __init__(self):
        super().__init__()
        # Custom initialization - could load ML models, connect to DBs, etc.
        self.custom_state = {"initialized_at": datetime.now().isoformat()}
    
    def _register_commands(self):
        """Register both inherited and new commands."""
        # First, register the generic commands by creating a temporary instance
        generic = GenericCommandHandler()
        
        # Copy all generic command registrations
        for cmd, handler in generic._command_registry.items():
            # Bind the handler methods to self to maintain state
            self.register_command(cmd, getattr(self, handler.__name__))
        
        # Add our custom commands
        self.register_command("hash", self.handle_hash)
        self.register_command("encode", self.handle_encode)
        self.register_command("custom_info", self.handle_custom_info)
    
    # Include all the generic command handlers
    def handle_ping(self, args):
        """Enhanced ping with custom data."""
        result = {
            "status": "ok",
            "bridge_type": "custom",  # Changed from "generic"
            "uptime": self.get_uptime(),
            "requests_handled": self.request_count,
            "timestamp": datetime.now().timestamp(),
            "python_version": sys.version,
            "worker_id": args.get("worker_id", "unknown"),
            "echo": args,
            "custom_data": {
                "handler_type": "CustomCommandHandler",
                "initialized_at": self.custom_state["initialized_at"]
            }
        }
        return result
    
    def handle_echo(self, args):
        """Echo command - unchanged from generic."""
        return {
            "status": "ok",
            "echoed": args,
            "timestamp": datetime.now().timestamp()
        }
    
    def handle_compute(self, args):
        """Compute command - unchanged from generic."""
        try:
            operation = args.get("operation", "add")
            a = args.get("a", 0)
            b = args.get("b", 0)
            
            if operation == "add":
                result = a + b
            elif operation == "subtract":
                result = a - b
            elif operation == "multiply":
                result = a * b
            elif operation == "divide":
                if b == 0:
                    raise ValueError("Division by zero")
                result = a / b
            else:
                raise ValueError(f"Unsupported operation: {operation}")
            
            return {
                "status": "ok",
                "operation": operation,
                "inputs": {"a": a, "b": b},
                "result": result,
                "timestamp": datetime.now().timestamp()
            }
        except Exception as e:
            return {
                "status": "error", 
                "error": str(e),
                "timestamp": datetime.now().timestamp()
            }
    
    def handle_info(self, args):
        """Enhanced info command."""
        return {
            "status": "ok",
            "bridge_info": {
                "name": "Custom Snakepit Bridge Example",
                "version": "2.0.0",
                "base_version": "2.0.0",
                "supported_commands": self.get_supported_commands(),
                "uptime": self.get_uptime(),
                "total_requests": self.request_count
            },
            "system_info": {
                "python_version": sys.version,
                "platform": sys.platform
            },
            "custom_info": self.custom_state,
            "timestamp": datetime.now().timestamp()
        }
    
    # New custom commands
    def handle_hash(self, args):
        """Generate hash of input text using specified algorithm."""
        text = args.get("text", "")
        algorithm = args.get("algorithm", "sha256")
        
        try:
            if algorithm == "sha256":
                hash_obj = hashlib.sha256(text.encode())
            elif algorithm == "md5":
                hash_obj = hashlib.md5(text.encode())
            elif algorithm == "sha1":
                hash_obj = hashlib.sha1(text.encode())
            else:
                raise ValueError(f"Unsupported algorithm: {algorithm}")
            
            return {
                "status": "ok",
                "algorithm": algorithm,
                "input": text,
                "hash": hash_obj.hexdigest(),
                "timestamp": datetime.now().timestamp()
            }
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "timestamp": datetime.now().timestamp()
            }
    
    def handle_encode(self, args):
        """Encode/decode text using base64."""
        text = args.get("text", "")
        operation = args.get("operation", "encode")
        
        try:
            if operation == "encode":
                result = base64.b64encode(text.encode()).decode()
            elif operation == "decode":
                result = base64.b64decode(text.encode()).decode()
            else:
                raise ValueError(f"Unsupported operation: {operation}")
            
            return {
                "status": "ok",
                "operation": operation,
                "input": text,
                "result": result,
                "timestamp": datetime.now().timestamp()
            }
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "timestamp": datetime.now().timestamp()
            }
    
    def handle_custom_info(self, args):
        """Demonstrate accessing custom state."""
        return {
            "status": "ok",
            "custom_state": self.custom_state,
            "handler_class": self.__class__.__name__,
            "additional_commands": [
                cmd for cmd in self.get_supported_commands() 
                if cmd not in ["ping", "echo", "compute", "info"]
            ],
            "timestamp": datetime.now().timestamp()
        }
    
    def get_uptime(self):
        """Helper method to calculate uptime."""
        return datetime.now().timestamp() - self.start_time


def main():
    """Main entry point for the custom bridge."""
    
    # Suppress broken pipe errors globally
    setup_broken_pipe_suppression()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Custom Snakepit Bridge Example V2")
        print("Usage: python example_custom_bridge_v2.py [--mode pool-worker]")
        print("")
        print("This example shows how to extend the generic bridge with custom commands.")
        print("Uses proper package imports instead of fragile sys.path manipulation.")
        print("")
        print("Supported commands:")
        handler = CustomCommandHandler()
        for cmd in sorted(handler.get_supported_commands()):
            print(f"  {cmd}")
        return
    
    # Create and run the custom bridge
    command_handler = CustomCommandHandler()
    protocol_handler = ProtocolHandler(command_handler)
    
    # Set up graceful shutdown handling
    setup_graceful_shutdown(protocol_handler)
    
    try:
        protocol_handler.run()
    except (KeyboardInterrupt, BrokenPipeError, IOError):
        os._exit(0)
    except Exception as e:
        from snakepit_bridge.core import safe_print
        safe_print(f"Bridge error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()