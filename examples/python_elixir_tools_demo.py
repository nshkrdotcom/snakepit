#!/usr/bin/env python3
"""
Demonstration of Python calling Elixir tools through the bidirectional bridge.

This example shows:
1. Discovering available Elixir tools
2. Calling Elixir tools from Python
3. Using tool proxies for seamless integration
4. Combining Python and Elixir capabilities

Configuration:
- Use --address (or SNAKEPIT_GRPC_ADDRESS) for the full gRPC address
- Use --host/--port (or SNAKEPIT_GRPC_HOST/SNAKEPIT_GRPC_PORT) if you prefer split args
- Use --session-id (or SNAKEPIT_SESSION_ID) to skip the prompt
"""

import sys
import os
import json
import asyncio
import argparse
from typing import Dict, Any

# Add parent directory to path for imports
sys.path.insert(0, '..')
sys.path.insert(0, 'priv/python')

from snakepit_bridge import configure_logging, get_logger

if __name__ == "__main__":
    configure_logging()

import grpc
from snakepit_bridge_pb2_grpc import BridgeServiceStub
from snakepit_bridge_pb2 import InitializeSessionRequest
from snakepit_bridge.session_context import SessionContext
from snakepit_bridge.base_adapter import BaseAdapter, tool
logger = get_logger(__name__)


def _default_port() -> int | None:
    value = os.getenv("SNAKEPIT_GRPC_PORT")
    if not value:
        return None
    try:
        return int(value)
    except ValueError as exc:
        raise SystemExit(f"Invalid SNAKEPIT_GRPC_PORT={value!r}; expected an integer.") from exc


def _parse_address(value: str) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host or not port:
        raise SystemExit(
            f"Invalid SNAKEPIT_GRPC_ADDRESS={value!r}; expected host:port."
        )
    try:
        return host, int(port)
    except ValueError as exc:
        raise SystemExit(
            f"Invalid SNAKEPIT_GRPC_ADDRESS={value!r}; expected host:port."
        ) from exc


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Python → Elixir tools demo")
    parser.add_argument(
        "--address",
        default=os.getenv("SNAKEPIT_GRPC_ADDRESS"),
        help="Elixir gRPC address (default: SNAKEPIT_GRPC_ADDRESS)",
    )
    parser.add_argument(
        "--host",
        default=os.getenv("SNAKEPIT_GRPC_HOST", "localhost"),
        help="Elixir gRPC host (default: localhost or SNAKEPIT_GRPC_HOST)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=_default_port(),
        help="Elixir gRPC port (default: SNAKEPIT_GRPC_PORT)",
    )
    parser.add_argument(
        "--session-id",
        default=os.getenv("SNAKEPIT_SESSION_ID"),
        help="Session ID to use (default: prompt or SNAKEPIT_SESSION_ID)",
    )
    args = parser.parse_args()

    if args.address:
        args.host, args.port = _parse_address(args.address)
    elif args.port is None:
        raise SystemExit(
            "Missing gRPC address; provide --address/--port or set SNAKEPIT_GRPC_ADDRESS/SNAKEPIT_GRPC_PORT."
        )

    return args


class DemoAdapter(BaseAdapter):
    """Example adapter that uses Elixir tools."""
    
    @tool(description="Analyze data using both Python and Elixir capabilities")
    def hybrid_analysis(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Demonstrates calling Elixir tools from within a Python tool.
        
        This shows how Python tools can leverage Elixir's capabilities
        for tasks like JSON parsing, data validation, or calculations.
        """
        # First, use Python for initial processing
        python_result = {
            'python_analysis': {
                'keys': list(data.keys()),
                'types': {k: type(v).__name__ for k, v in data.items()},
                'size': len(data)
            }
        }
        
        # Then call Elixir tool for JSON validation/parsing
        if hasattr(self, 'session_context') and self.session_context:
            try:
                # Convert data to JSON string for Elixir's parse_json tool
                json_str = json.dumps(data)
                elixir_result = self.session_context.call_elixir_tool(
                    'parse_json',
                    json_string=json_str
                )
                python_result['elixir_validation'] = elixir_result
            except Exception as e:
                python_result['elixir_error'] = str(e)
        
        return python_result
    
    @tool(description="Calculate statistics using Elixir's process_list tool")
    def calculate_stats(self, numbers: list) -> Dict[str, Any]:
        """Use Elixir to calculate various statistics on a list."""
        if not hasattr(self, 'session_context') or not self.session_context:
            return {'error': 'No session context available'}
        
        results = {}
        operations = ['sum', 'max', 'min', 'mean']
        
        for op in operations:
            try:
                result = self.session_context.call_elixir_tool(
                    'process_list',
                    list=numbers,
                    operation=op
                )
                results[op] = result
            except Exception as e:
                results[f'{op}_error'] = str(e)
        
        return results


async def main():
    """Run the demonstration."""
    args = _parse_args()

    # Connect to Elixir gRPC server
    channel = grpc.insecure_channel(f"{args.host}:{args.port}")
    stub = BridgeServiceStub(channel)
    
    # Get session ID from user or use default
    if args.session_id:
        session_id = args.session_id
    else:
        print("Enter the session ID from the Elixir demo (or press Enter for default):")
        user_input = input().strip()
        session_id = user_input if user_input else "bidirectional-demo"

    print(f"\nUsing session ID: {session_id}")
    
    # Skip session initialization since the Elixir demo already created it
    logger.info(f"Connecting to existing session: {session_id}")
    
    # Create session context
    ctx = SessionContext(stub, session_id)
    
    print("\n=== Python → Elixir Tool Demo ===\n")
    
    # 1. Discover available Elixir tools
    print("1. Available Elixir tools:")
    for name, tool_proxy in ctx.elixir_tools.items():
        print(f"   - {name}: {tool_proxy.__doc__ or 'No description'}")
    
    # 2. Direct tool calls
    print("\n2. Direct Elixir tool calls:")
    
    # Call parse_json
    test_json = {"name": "Python Test", "value": 123, "nested": {"a": 1, "b": 2}}
    json_result = ctx.call_elixir_tool('parse_json', json_string=json.dumps(test_json))
    print(f"   parse_json result: {json_result}")
    
    # Call calculate_fibonacci
    fib_result = ctx.call_elixir_tool('calculate_fibonacci', n=10)
    print(f"   fibonacci(10): {fib_result}")
    
    # Call process_list
    numbers = [5, 2, 8, 1, 9, 3, 7]
    list_result = ctx.call_elixir_tool('process_list', list=numbers, operation='mean')
    print(f"   mean of {numbers}: {list_result}")
    
    # 3. Using tool proxies
    print("\n3. Using Elixir tool proxies:")
    
    # Get tool proxy
    process_list = ctx.elixir_tools.get('process_list')
    if process_list:
        # Call it like a regular Python function
        sum_result = process_list(list=[10, 20, 30, 40], operation='sum')
        print(f"   sum via proxy: {sum_result}")
    
    # 4. Python adapter with Elixir integration
    print("\n4. Hybrid Python-Elixir processing:")
    
    adapter = DemoAdapter()
    adapter.session_context = ctx
    
    # Register adapter tools
    registered = adapter.register_with_session(session_id, stub)
    print(f"   Registered Python tools: {registered}")
    
    # Call hybrid tool
    test_data = {
        "id": 123,
        "name": "Test Item",
        "scores": [85, 92, 78, 95],
        "metadata": {"category": "demo", "priority": "high"}
    }
    
    hybrid_result = adapter.hybrid_analysis(test_data)
    print(f"   Hybrid analysis: {json.dumps(hybrid_result, indent=2)}")
    
    # Calculate statistics using Elixir
    stats = adapter.calculate_stats([10, 20, 30, 40, 50])
    print(f"   Statistics via Elixir: {json.dumps(stats, indent=2)}")
    
    # 5. Advanced integration patterns
    print("\n5. Advanced patterns:")
    
    # Chain multiple Elixir tools
    # First, generate Fibonacci sequence
    fib = ctx.call_elixir_tool('calculate_fibonacci', n=15)
    print(f"   Generated Fibonacci sequence (n=15): {fib['sequence']}")
    
    # Then process it with different operations
    for op in ['sum', 'max', 'mean']:
        result = ctx.call_elixir_tool('process_list', list=fib['sequence'], operation=op)
        print(f"   Fibonacci {op}: {result['result']}")
    
    print("\n=== Demo Complete ===")
    print("Python successfully called Elixir tools through the bidirectional bridge!")
    print("This enables leveraging the best of both languages in a single application.")
    
    # Cleanup
    channel.close()


if __name__ == "__main__":
    asyncio.run(main())
