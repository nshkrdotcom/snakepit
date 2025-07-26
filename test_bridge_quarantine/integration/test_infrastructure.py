"""
Test infrastructure for integration testing the unified bridge variable system.
"""

import subprocess
import time
import socket
import os
import tempfile
import shutil
from contextlib import contextmanager
from typing import Generator, Tuple
import grpc
from concurrent.futures import ThreadPoolExecutor
import sys
import signal

# Add the Python bridge to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../priv/python'))

from snakepit_bridge import SessionContext
from snakepit_bridge_pb2_grpc import BridgeServiceStub


class TestServer:
    """Manages test server lifecycle."""
    
    def __init__(self, port: int = 0):
        self.port = port or self._find_free_port()
        self.process = None
        self.temp_dir = None
    
    @staticmethod
    def _find_free_port() -> int:
        """Find an available port."""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(('', 0))
            s.listen(1)
            return s.getsockname()[1]
    
    def start(self):
        """Start the Elixir gRPC server."""
        # Create temp directory for server
        self.temp_dir = tempfile.mkdtemp()
        
        # Get the snakepit directory
        snakepit_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
        
        # Start server with test configuration
        env = os.environ.copy()
        env['MIX_ENV'] = 'test'
        env['GRPC_PORT'] = str(self.port)
        env['BRIDGE_DATA_DIR'] = self.temp_dir
        
        # Create a simple mix task to start the gRPC server
        start_script = f"""
        # Start the gRPC endpoint
        {{:ok, _pid, port}} = GRPC.Server.start_endpoint(Snakepit.GRPC.Endpoint, {self.port})
        IO.puts("gRPC server started on port #{{port}}")
        
        # Keep the process alive
        Process.sleep(:infinity)
        """
        
        # Start server process using mix run with inline script
        self.process = subprocess.Popen(
            ['mix', 'run', '-e', start_script],
            cwd=snakepit_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Wait for server to be ready
        self._wait_for_ready()
    
    def _wait_for_ready(self, timeout: float = 30.0):
        """Wait for server to start accepting connections."""
        start_time = time.time()
        
        while time.time() - start_time < timeout:
            # Check if process is still running
            if self.process.poll() is not None:
                stdout, stderr = self.process.communicate()
                raise RuntimeError(f"Server failed to start:\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}")
            
            # Try to connect
            try:
                channel = grpc.insecure_channel(f'localhost:{self.port}')
                grpc.channel_ready_future(channel).result(timeout=1)
                channel.close()
                print(f"Server ready on port {self.port}")
                return
            except:
                time.sleep(0.1)
        
        raise TimeoutError("Server failed to start within timeout")
    
    def stop(self):
        """Stop the server and cleanup."""
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        
        if self.temp_dir and os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)


@contextmanager
def test_server() -> Generator[TestServer, None, None]:
    """Context manager for test server."""
    server = TestServer()
    try:
        server.start()
        yield server
    finally:
        server.stop()


@contextmanager
def test_session(server: TestServer) -> Generator[SessionContext, None, None]:
    """Create a test session context."""
    channel = grpc.insecure_channel(f'localhost:{server.port}')
    stub = BridgeServiceStub(channel)
    
    session_id = f"test_session_{int(time.time() * 1000)}"
    
    # Initialize session via gRPC
    from snakepit_bridge_pb2 import InitializeSessionRequest
    init_request = InitializeSessionRequest(session_id=session_id)
    init_response = stub.InitializeSession(init_request)
    
    if not init_response.success:
        raise RuntimeError(f"Failed to initialize session: {init_response.error_message}")
    
    ctx = SessionContext(stub, session_id)
    
    try:
        yield ctx
    finally:
        # Cleanup session
        from snakepit_bridge_pb2 import CleanupSessionRequest
        cleanup_request = CleanupSessionRequest(session_id=session_id, force=True)
        stub.CleanupSession(cleanup_request)
        channel.close()


class TestMetrics:
    """Collect test metrics."""
    
    def __init__(self):
        self.timings = {}
        self.counters = {}
    
    @contextmanager
    def time(self, name: str):
        """Time an operation."""
        start = time.time()
        try:
            yield
        finally:
            duration = time.time() - start
            if name not in self.timings:
                self.timings[name] = []
            self.timings[name].append(duration)
    
    def count(self, name: str, value: int = 1):
        """Count occurrences."""
        if name not in self.counters:
            self.counters[name] = 0
        self.counters[name] += value
    
    def report(self):
        """Print metrics report."""
        print("\n=== Performance Metrics ===")
        
        for name, times in sorted(self.timings.items()):
            if times:
                avg = sum(times) / len(times)
                min_time = min(times)
                max_time = max(times)
                print(f"{name}:")
                print(f"  Average: {avg*1000:.2f}ms")
                print(f"  Min: {min_time*1000:.2f}ms")
                print(f"  Max: {max_time*1000:.2f}ms")
        
        if self.counters:
            print("\nCounters:")
            for name, count in sorted(self.counters.items()):
                print(f"  {name}: {count}")


def run_test_server():
    """Run a test server standalone for debugging."""
    print("Starting test server...")
    server = TestServer()
    
    def signal_handler(sig, frame):
        print("\nShutting down test server...")
        server.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    
    server.start()
    print(f"Test server running on port {server.port}")
    print("Press Ctrl+C to stop...")
    
    # Keep running
    while True:
        time.sleep(1)


if __name__ == '__main__':
    run_test_server()