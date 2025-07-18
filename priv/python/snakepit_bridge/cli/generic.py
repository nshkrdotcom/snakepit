#!/usr/bin/env python3
"""
Generic Snakepit Bridge CLI

Console script entry point for the generic bridge.
This provides the same functionality as generic_bridge_v2.py but
as an installed console script.
"""

import sys
import os

from ..adapters.generic import GenericCommandHandler
from ..core import ProtocolHandler, setup_graceful_shutdown, setup_broken_pipe_suppression


def main():
    """Main entry point for the generic bridge console script."""
    
    # Suppress broken pipe errors globally
    setup_broken_pipe_suppression()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Generic Snakepit Bridge V2 (Console Script)")
        print("Usage: snakepit-generic-bridge [--mode pool-worker]")
        print("")
        print("This bridge provides an extensible architecture for creating custom adapters.")
        print("Installed as a console script from the snakepit-bridge package.")
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
        from ..core import safe_print
        safe_print(f"Bridge error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()