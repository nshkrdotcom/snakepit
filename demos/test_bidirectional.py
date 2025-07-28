#!/usr/bin/env python3
"""Quick test of bidirectional tool calling."""

import sys
sys.path.insert(0, 'priv/python')

import grpc
from snakepit_bridge_pb2_grpc import BridgeServiceStub
from snakepit_bridge.session_context import SessionContext
import json

# Connect to Elixir
channel = grpc.insecure_channel('localhost:50051')
stub = BridgeServiceStub(channel)

# Use existing session
session_id = "bidirectional-demo"
ctx = SessionContext(stub, session_id)

print("Available Elixir tools:", list(ctx.elixir_tools.keys()))

# Test parse_json
if 'parse_json' in ctx.elixir_tools:
    test_data = {"hello": "world", "number": 42}
    result = ctx.call_elixir_tool('parse_json', json_string=json.dumps(test_data))
    print("Parse JSON result:", result)

# Test fibonacci
if 'calculate_fibonacci' in ctx.elixir_tools:
    result = ctx.call_elixir_tool('calculate_fibonacci', n=10)
    print("Fibonacci result:", result)

# Test process_list
if 'process_list' in ctx.elixir_tools:
    result = ctx.call_elixir_tool('process_list', list=[1, 2, 3, 4, 5], operation='sum')
    print("Process list result:", result)