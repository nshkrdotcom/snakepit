#!/usr/bin/env python3
"""Test gRPC streaming with correct encoding"""
import grpc
import sys
import json
sys.path.append('/home/home/p/g/n/dspex/snakepit/priv/python')

from snakepit_bridge.grpc import snakepit_bridge_pb2 as pb2
from snakepit_bridge.grpc import snakepit_bridge_pb2_grpc as pb2_grpc
from google.protobuf.any_pb2 import Any

# Connect to Python gRPC server
channel = grpc.insecure_channel('localhost:50053')
stub = pb2_grpc.BridgeServiceStub(channel)

# Create request
request = pb2.ExecuteToolRequest()
request.session_id = "test_session"
request.tool_name = "stream_progress"
request.stream = True

# Add parameter - matching how Elixir encodes it
steps_any = Any()
steps_any.type_url = "type.googleapis.com/snakepit.integer"
# Encode as JSON string matching Elixir's format
steps_any.value = json.dumps(3).encode('utf-8')
request.parameters["steps"].CopyFrom(steps_any)

print(f"Sending request with JSON-encoded parameters")
print(f"steps type_url: {steps_any.type_url}")
print(f"steps value: {steps_any.value}")

try:
    # Call streaming RPC
    stream = stub.ExecuteStreamingTool(request)
    print(f"Got stream: {stream}")
    
    # Consume stream
    for i, chunk in enumerate(stream):
        print(f"Chunk {i}: chunk_id={chunk.chunk_id}, data={chunk.data}, is_final={chunk.is_final}")
        if chunk.is_final and not chunk.data:
            print("Received final chunk")
            break
        if i > 10:  # Safety limit
            break
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()