#!/usr/bin/env python3
"""
Generic Python Bridge for Snakepit V2

A minimal, framework-agnostic bridge that demonstrates the protocol
without dependencies on any specific ML framework.

This version uses the proper snakepit_bridge package structure for
robust, production-ready bridge implementations.

To create a custom adapter:
1. Create a new class that inherits from BaseCommandHandler
2. Override _register_commands() to register your command handlers
3. Implement your command handler methods
4. Pass an instance of your handler to ProtocolHandler

Example:
    from snakepit_bridge import BaseCommandHandler, ProtocolHandler
    
    class MyCustomHandler(BaseCommandHandler):
        def _register_commands(self):
            self.register_command("my_command", self.handle_my_command)
        
        def handle_my_command(self, args):
            return {"result": "processed", "input": args}
    
    handler = ProtocolHandler(MyCustomHandler())
    handler.run()
"""

import sys
import os

# Add the bridge package to Python path if not already installed
if __name__ == "__main__":
    bridge_dir = os.path.dirname(os.path.abspath(__file__))
    if bridge_dir not in sys.path:
        sys.path.insert(0, bridge_dir)

from snakepit_bridge import GenericCommandHandler, ProtocolHandler
from snakepit_bridge.core import setup_graceful_shutdown, setup_broken_pipe_suppression


def main():
    """Main entry point."""
    
    # Suppress broken pipe errors globally
    setup_broken_pipe_suppression()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Generic Snakepit Bridge V2")
        print("Usage: python generic_bridge_v2.py [--mode pool-worker]")
        print("")
        print("This bridge provides an extensible architecture for creating custom adapters.")
        print("See the module docstring for examples on how to create your own adapter.")
        print("")
        print("Default supported commands:")
        handler = GenericCommandHandler()
        for cmd in sorted(handler.get_supported_commands()):
            print(f"  {cmd}")
        return
    
    # Create protocol handler with generic command handler
    command_handler = GenericCommandHandler()
    protocol_handler = ProtocolHandler(command_handler)
    
    # Set up graceful shutdown handling
    setup_graceful_shutdown(protocol_handler)
    
    # Start protocol handler
    try:
        protocol_handler.run()
    except (KeyboardInterrupt, BrokenPipeError, IOError):
        # Clean shutdown, suppress errors
        os._exit(0)
    except Exception as e:
        from snakepit_bridge.core import safe_print
        safe_print(f"Bridge error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()