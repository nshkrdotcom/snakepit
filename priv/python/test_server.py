#!/usr/bin/env python3
"""
Test the gRPC server startup
"""

import sys
import os

# Add the package to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Test imports first
try:
    from snakepit_bridge import snakepit_bridge_pb2
    from snakepit_bridge import snakepit_bridge_pb2_grpc
    print("✓ Successfully imported generated protobuf modules")
except ImportError as e:
    print(f"✗ Failed to import protobuf modules: {e}")
    sys.exit(1)

try:
    from snakepit_bridge.session_context import SessionContext
    from snakepit_bridge.serialization import TypeSerializer
    print("✓ Successfully imported bridge modules")
except ImportError as e:
    print(f"✗ Failed to import bridge modules: {e}")
    sys.exit(1)

# Test starting the server
import subprocess
import time
import signal

print("\nStarting gRPC server...")
proc = subprocess.Popen(
    [sys.executable, "grpc_server.py", "--port", "50051"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    universal_newlines=True
)

# Wait for server to start
ready = False
start_time = time.time()
while time.time() - start_time < 10:
    line = proc.stdout.readline()
    if line:
        print(f"Server output: {line.strip()}")
        if "GRPC_READY:" in line:
            ready = True
            break
    
    # Check if process died
    if proc.poll() is not None:
        stderr = proc.stderr.read()
        print(f"Server died with error:\n{stderr}")
        sys.exit(1)

if ready:
    print("\n✓ Server started successfully!")
    print("Shutting down server...")
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=5)
    print("✓ Server shutdown cleanly")
else:
    print("\n✗ Server failed to start within timeout")
    proc.kill()
    sys.exit(1)