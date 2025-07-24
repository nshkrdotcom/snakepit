#!/usr/bin/env python3
"""Test gRPC streaming directly"""
import grpc
import sys
import time
sys.path.append('/home/home/p/g/n/dspex/snakepit/priv/python')

import snakepit_bridge_pb2 as pb2
import snakepit_bridge_pb2_grpc as pb2_grpc
from google.protobuf.any_pb2 import Any
from google.protobuf.wrappers_pb2 import Int32Value

# Connect to Python gRPC server
channel = grpc.insecure_channel('localhost:50053')
stub = pb2_grpc.BridgeServiceStub(channel)

# Create request
request = pb2.ExecuteToolRequest()
request.session_id = "test_session"
request.tool_name = "stream_progress"
request.stream = True

# Add parameter
steps_value = Int32Value(value=3)
steps_any = Any()
steps_any.Pack(steps_value)
request.parameters["steps"].CopyFrom(steps_any)

print(f"Sending request: {request}")

try:
    # Call streaming RPC
    stream = stub.ExecuteStreamingTool(request)
    print(f"Got stream: {stream}")
    
    # Consume stream
    for i, chunk in enumerate(stream):
        print(f"Chunk {i}: {chunk}")
        if i > 10:  # Safety limit
            break
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()