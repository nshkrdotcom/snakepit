# Python Worker Guide: Calling Elixir from Python

- **Date**: 2025-07-31
- **Status**: Draft

## 1. Introduction

This guide is for Python developers who are writing scripts that will be run as worker processes by `snakepit`.

While the primary communication flow is from Elixir to Python (with Elixir calling your script to execute commands), sometimes your Python worker may need to access a function or service provided by the Elixir host. This is often called "bidirectional communication."

The `snakepit_bridge` Python library is provided to make this easy. It allows your Python script to seamlessly call registered "tools" in the Elixir host.

## 2. The `snakepit_bridge` Library

The `snakepit_bridge` is a Python library that handles the complexity of communicating back to the Elixir host over gRPC. It is typically included in the Elixir project's `priv/python` directory. Your Python script will need to have this directory in its `PYTHONPATH`.

```python
import sys
# Add the snakepit_bridge library to the path
sys.path.insert(0, 'priv/python')

from snakepit_bridge.session_context import SessionContext
```

## 3. Getting Started: The `SessionContext`

The `SessionContext` is the main object you will interact with. It represents your worker's session and manages the underlying gRPC connection to the Elixir host.

To create a `SessionContext`, you need two things which your adapter should provide to your script (e.g., as command-line arguments):
1.  The `host:port` of the Elixir gRPC server.
2.  A unique `session_id` for your worker instance.

Here is how you initialize the context:

```python
import grpc
from snakepit_bridge_pb2_grpc import BridgeServiceStub
from snakepit_bridge.session_context import SessionContext

# These values should be passed to your script by the adapter
ELIXIR_GRPC_ADDRESS = 'localhost:50051'
SESSION_ID = 'some-unique-session-id' # Provided by the adapter

# 1. Create a gRPC channel and stub
channel = grpc.insecure_channel(ELIXIR_GRPC_ADDRESS)
stub = BridgeServiceStub(channel)

# 2. Create the SessionContext
ctx = SessionContext(stub, SESSION_ID)
```

Once `ctx` is created, you are ready to interact with Elixir.

## 4. Using the `SessionContext`

### Listing Available Tools

The Elixir host can expose a set of "tools" (public functions) that remote workers can call. You can easily see a list of these tools.

```python
# Get a list of available tool names
available_tools = list(ctx.elixir_tools.keys())

print(f"Available Elixir tools: {available_tools}")
# => Available Elixir tools: ['parse_json', 'calculate_fibonacci', 'process_list']
```

### Calling an Elixir Tool

To call an Elixir function, use the `call_elixir_tool` method. The first argument is the name of the tool, and all subsequent keyword arguments are passed as the arguments to the Elixir function.

```python
# Example 1: Calling a fibonacci calculator
# This would call a function like `def calculate_fibonacci(params)` in Elixir,
# where params is a map like %{"n" => 10}
result = ctx.call_elixir_tool('calculate_fibonacci', n=10)
print(f"The 10th fibonacci number is: {result}")


# Example 2: Calling a tool that processes a list
# The list will be serialized to Elixir's list format automatically.
result = ctx.call_elixir_tool('process_list', data=[1, 2, 3, 4, 5], operation='sum')
print(f"The sum of the list is: {result}")
```

## 5. Complete Example Script

Here is a complete, documented example of a Python worker script that connects back to Elixir.

```python
#!/usr/bin/env python3
"""
An example Python worker script that demonstrates how to call back
into the Elixir host using the SessionContext.
"""

import sys
import grpc
import json

# Assume the snakepit_bridge library is in a reachable path
sys.path.insert(0, 'priv/python')
from snakepit_bridge_pb2_grpc import BridgeServiceStub
from snakepit_bridge.session_context import SessionContext

def main(grpc_address, session_id):
    """
    Connects to the Elixir host and demonstrates tool calling.
    """
    print(f"Python worker started with session_id: {session_id}")
    print(f"Connecting to Elixir gRPC server at: {grpc_address}")

    try:
        # --- 1. Setup Connection ---
        channel = grpc.insecure_channel(grpc_address)
        stub = BridgeServiceStub(channel)
        ctx = SessionContext(stub, session_id)

        # --- 2. List Available Tools ---
        available_tools = list(ctx.elixir_tools.keys())
        print(f"\nDiscovered available Elixir tools: {available_tools}")

        # --- 3. Call Tools ---
        if 'calculate_fibonacci' in available_tools:
            print("\nCalling 'calculate_fibonacci' tool...")
            fib_result = ctx.call_elixir_tool('calculate_fibonacci', n=12)
            print(f"  -> Result: {fib_result}")

        if 'parse_json' in available_tools:
            print("\nCalling 'parse_json' tool...")
            test_data = {"hello": "world", "is_python": True}
            parse_result = ctx.call_elixir_tool('parse_json', json_string=json.dumps(test_data))
            print(f"  -> Result: {parse_result}")

        print("\nPython worker finished.")

    except grpc.RpcError as e:
        print(f"An error occurred: {e.status()}: {e.details()}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    # In a real application, the adapter would pass these values
    # as command-line arguments to this script.
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <grpc_address> <session_id>", file=sys.stderr)
        sys.exit(1)

    main(grpc_address=sys.argv[1], session_id=sys.argv[2])
```
