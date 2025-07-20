#!/usr/bin/env python3
"""
Test gRPC bridge for streaming demo.

This uses the test adapter that implements streaming commands.
"""

import sys
import os

# Add the parent directory to the path so we can import snakepit_bridge
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from grpc_bridge import serve
from snakepit_bridge.adapters.grpc_streaming_test import GRPCStreamingTestHandler

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Test gRPC Bridge')
    parser.add_argument('--port', type=int, default=50051, help='Port to listen on')
    args = parser.parse_args()
    
    # Use our test adapter directly
    print(f"Starting test gRPC bridge with streaming test adapter on port {args.port}", file=sys.stderr)
    serve(args.port, GRPCStreamingTestHandler)