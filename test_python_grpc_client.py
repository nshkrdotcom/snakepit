#!/usr/bin/env python3

import grpc
import sys
import time

# Add the path to the generated protobuf files
sys.path.insert(0, 'priv/python')

from snakepit_bridge.grpc import snakepit_pb2, snakepit_pb2_grpc

def test_streaming():
    # Connect to the gRPC server
    channel = grpc.insecure_channel('localhost:50061')
    stub = snakepit_pb2_grpc.SnakepitBridgeStub(channel)
    
    # Create a request
    request = snakepit_pb2.ExecuteRequest(
        command="ping_stream",
        args={
            "count": b"3",
            "interval": b"0.1"
        },
        timeout_ms=10000,
        request_id="python_test"
    )
    
    print(f"Sending request: {request.command}")
    
    try:
        # Call the streaming RPC
        responses = stub.ExecuteStream(request)
        
        # Consume the stream
        for i, response in enumerate(responses):
            print(f"Received chunk {i}: {response.chunk}")
            
        print("Stream completed successfully!")
        
    except grpc.RpcError as e:
        print(f"RPC failed: {e.code()} - {e.details()}")

if __name__ == "__main__":
    # First start a gRPC server manually
    import subprocess
    import os
    
    # Start server
    server_proc = subprocess.Popen([
        sys.executable,
        "priv/python/grpc_bridge.py",
        "--port", "50061",
        "--adapter", "snakepit_bridge.adapters.grpc_streaming.GRPCStreamingHandler"
    ], stderr=subprocess.PIPE)
    
    # Wait for server to start
    time.sleep(2)
    
    # Test streaming
    test_streaming()
    
    # Clean up
    server_proc.terminate()
    server_proc.wait()