#!/usr/bin/env python3
"""
gRPC Bridge for Snakepit

A modern gRPC-based bridge that replaces the stdin/stdout protocol with proper
streaming, multiplexing, and performance benefits.

Usage:
    python grpc_bridge.py --port 50051
    python grpc_bridge.py --port 50051 --adapter my_custom_adapter
"""

import os
import sys
import argparse
import time
import json
import signal
import threading
from concurrent import futures
from typing import Dict, Any, Iterator, Optional

# gRPC imports with graceful fallback
try:
    import grpc
    from grpc import ServicerContext
    GRPC_AVAILABLE = True
except ImportError:
    print("ERROR: gRPC not available. Install with: pip install 'snakepit-bridge[grpc]'", file=sys.stderr)
    sys.exit(1)

# Import generated protobuf code
try:
    from snakepit_bridge.grpc import snakepit_pb2, snakepit_pb2_grpc
except ImportError:
    print("ERROR: Generated gRPC code not found. Run 'make proto-python' first.", file=sys.stderr)
    sys.exit(1)

# Import existing command handlers
from snakepit_bridge.adapters.generic import GenericCommandHandler
from snakepit_bridge.core import BaseCommandHandler


class SnakepitBridgeServicer(snakepit_pb2_grpc.SnakepitBridgeServicer):
    """gRPC service implementation for Snakepit bridge."""
    
    def __init__(self, command_handler: BaseCommandHandler):
        self.command_handler = command_handler
        self.start_time = time.time()
        self.request_count = 0
        self.error_count = 0
        self.active_sessions = set()
        self._lock = threading.Lock()
        
    def _track_request(self, success: bool = True):
        """Thread-safe request tracking."""
        with self._lock:
            self.request_count += 1
            if not success:
                self.error_count += 1
    
    def _convert_args(self, grpc_args: Dict[str, bytes]) -> Dict[str, Any]:
        """Convert gRPC bytes args to Python objects."""
        result = {}
        for key, value in grpc_args.items():
            try:
                # Try to decode as JSON first
                decoded = value.decode('utf-8')
                try:
                    result[key] = json.loads(decoded)
                except json.JSONDecodeError:
                    # If not JSON, keep as string
                    result[key] = decoded
            except UnicodeDecodeError:
                # Keep as bytes for binary data
                result[key] = value
        return result
    
    def _convert_result(self, python_result: Any) -> Dict[str, bytes]:
        """Convert Python result to gRPC bytes format."""
        if isinstance(python_result, dict):
            result = {}
            for key, value in python_result.items():
                if isinstance(value, bytes):
                    result[key] = value
                elif isinstance(value, str):
                    result[key] = value.encode('utf-8')
                else:
                    result[key] = json.dumps(value).encode('utf-8')
            return result
        else:
            return {"result": json.dumps(python_result).encode('utf-8')}
    
    def Execute(self, request: snakepit_pb2.ExecuteRequest, context: ServicerContext) -> snakepit_pb2.ExecuteResponse:
        """Handle simple request/response execution."""
        try:
            # Convert gRPC request to legacy format
            args = self._convert_args(request.args)
            
            # Execute command using existing handler
            if hasattr(self.command_handler, 'process_command'):
                result = self.command_handler.process_command(request.command, args)
            elif hasattr(self.command_handler, 'handle_command'):
                result = self.command_handler.handle_command(request.command, args)
            else:
                # Fallback to direct method dispatch
                handlers = self.command_handler._command_registry if hasattr(self.command_handler, '_command_registry') else {}
                handler = handlers.get(request.command)
                if not handler:
                    raise ValueError(f"Unknown command: {request.command}")
                result = handler(args)
            
            self._track_request(success=True)
            
            return snakepit_pb2.ExecuteResponse(
                success=True,
                result=self._convert_result(result),
                timestamp=int(time.time() * 1_000_000_000),  # nanoseconds
                request_id=request.request_id
            )
            
        except Exception as e:
            self._track_request(success=False)
            return snakepit_pb2.ExecuteResponse(
                success=False,
                error=str(e),
                timestamp=int(time.time() * 1_000_000_000),
                request_id=request.request_id
            )
    
    def ExecuteStream(self, request: snakepit_pb2.ExecuteRequest, context: ServicerContext) -> Iterator[snakepit_pb2.StreamResponse]:
        """Handle streaming execution."""
        print(f"[gRPC Bridge] ExecuteStream called with command: {request.command}, request_id: {request.request_id}", file=sys.stderr, flush=True)
        try:
            args = self._convert_args(request.args)
            print(f"[gRPC Bridge] Converted args: {args}", file=sys.stderr, flush=True)
            
            # Check if command handler supports streaming
            if hasattr(self.command_handler, 'process_stream_command'):
                print(f"[gRPC Bridge] Handler supports streaming, delegating to process_stream_command", file=sys.stderr, flush=True)
                # Handler supports streaming - delegate to it
                chunk_index = 0
                for result_chunk in self.command_handler.process_stream_command(request.command, args):
                    # *** CRITICAL: Check if gRPC context is still active ***
                    if not context.is_active():
                        print(f"gRPC context became inactive. Terminating stream for request {request.request_id}.", file=sys.stderr)
                        break  # Exit the loop gracefully
                    
                    print(f"[gRPC Bridge] Received chunk {chunk_index}: {result_chunk}", file=sys.stderr, flush=True)
                    
                    response = snakepit_pb2.StreamResponse(
                        is_final=result_chunk.get('is_final', False),
                        chunk=self._convert_result(result_chunk.get('data', {})),
                        error=result_chunk.get('error', ''),
                        timestamp=int(time.time() * 1_000_000_000),
                        request_id=request.request_id,
                        chunk_index=chunk_index
                    )
                    print(f"[gRPC Bridge] Yielding StreamResponse: is_final={response.is_final}, chunk_index={response.chunk_index}", file=sys.stderr, flush=True)
                    yield response
                    chunk_index += 1
                
                print(f"[gRPC Bridge] Stream loop completed for request {request.request_id}", file=sys.stderr, flush=True)
            else:
                print(f"[gRPC Bridge] Handler does not support streaming, falling back to Execute", file=sys.stderr, flush=True)
                # Fallback: execute normally and return single result
                result = self.Execute(request, context)
                yield snakepit_pb2.StreamResponse(
                    is_final=True,
                    chunk=result.result,
                    error=result.error if not result.success else "",
                    timestamp=result.timestamp,
                    request_id=request.request_id,
                    chunk_index=0
                )
            
            self._track_request(success=True)
            print(f"[gRPC Bridge] ExecuteStream completed successfully for request {request.request_id}", file=sys.stderr, flush=True)
            
        except Exception as e:
            print(f"[gRPC Bridge] ExecuteStream error: {e}", file=sys.stderr, flush=True)
            import traceback
            traceback.print_exc()
            self._track_request(success=False)
            yield snakepit_pb2.StreamResponse(
                is_final=True,
                error=str(e),
                timestamp=int(time.time() * 1_000_000_000),
                request_id=request.request_id,
                chunk_index=0
            )
    
    def ExecuteInSession(self, request: snakepit_pb2.SessionRequest, context: ServicerContext) -> snakepit_pb2.ExecuteResponse:
        """Handle session-based execution."""
        with self._lock:
            self.active_sessions.add(request.session_id)
        
        try:
            # For now, treat session execution same as regular execution
            # In future, could maintain session state here
            exec_request = snakepit_pb2.ExecuteRequest(
                command=request.command,
                args=request.args,
                timeout_ms=request.timeout_ms,
                request_id=request.request_id
            )
            
            return self.Execute(exec_request, context)
            
        finally:
            with self._lock:
                self.active_sessions.discard(request.session_id)
    
    def ExecuteInSessionStream(self, request: snakepit_pb2.SessionRequest, context: ServicerContext) -> Iterator[snakepit_pb2.StreamResponse]:
        """Handle session-based streaming execution."""
        with self._lock:
            self.active_sessions.add(request.session_id)
        
        try:
            exec_request = snakepit_pb2.ExecuteRequest(
                command=request.command,
                args=request.args,
                timeout_ms=request.timeout_ms,
                request_id=request.request_id
            )
            
            yield from self.ExecuteStream(exec_request, context)
            
        finally:
            with self._lock:
                self.active_sessions.discard(request.session_id)
    
    def Health(self, request: snakepit_pb2.HealthRequest, context: ServicerContext) -> snakepit_pb2.HealthResponse:
        """Handle health check."""
        uptime_ms = int((time.time() - self.start_time) * 1000)
        
        return snakepit_pb2.HealthResponse(
            healthy=True,
            worker_id=request.worker_id or f"grpc_worker_{id(self)}",
            uptime_ms=uptime_ms,
            total_requests=self.request_count,
            total_errors=self.error_count,
            version="1.0.0-grpc"
        )
    
    def GetInfo(self, request: snakepit_pb2.InfoRequest, context: ServicerContext) -> snakepit_pb2.InfoResponse:
        """Get worker information and capabilities."""
        # Get supported commands from handler
        if hasattr(self.command_handler, 'get_supported_commands'):
            commands = self.command_handler.get_supported_commands()
        elif hasattr(self.command_handler, 'get_commands'):
            commands = list(self.command_handler.get_commands().keys())
        else:
            commands = ['ping', 'echo', 'compute']  # fallback
        
        stats = None
        if request.include_stats:
            uptime_ms = int((time.time() - self.start_time) * 1000)
            stats = snakepit_pb2.WorkerStats(
                requests_handled=self.request_count,
                requests_failed=self.error_count,
                uptime_ms=uptime_ms,
                memory_usage_bytes=0,  # Could implement with psutil
                cpu_usage_percent=0.0,
                active_sessions=len(self.active_sessions)
            )
        
        return snakepit_pb2.InfoResponse(
            worker_type="python-grpc",
            version="1.0.0",
            supported_commands=commands,
            capabilities={
                "streaming": "true",
                "sessions": "true", 
                "binary_data": "true"
            },
            stats=stats,
            system_info={
                "python_version": sys.version,
                "grpc_version": grpc.__version__,
            }
        )


def serve(port: int, adapter_class=None):
    """Start the gRPC server."""
    # Use provided adapter or default to GenericCommandHandler
    if adapter_class:
        command_handler = adapter_class()
    else:
        command_handler = GenericCommandHandler()
    
    # Create service
    servicer = SnakepitBridgeServicer(command_handler)
    
    # Create server
    max_workers = os.cpu_count() or 4 
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=max_workers),
        options=[
            ('grpc.keepalive_time_ms', 10000),
            ('grpc.keepalive_timeout_ms', 5000),
            ('grpc.keepalive_permit_without_calls', True),
            ('grpc.http2.max_pings_without_data', 0),
            ('grpc.http2.min_time_between_pings_ms', 10000),
            ('grpc.http2.min_ping_interval_without_data_ms', 5000)
        ]
    )
    
    # Add service to server
    snakepit_pb2_grpc.add_SnakepitBridgeServicer_to_server(servicer, server)
    
    # Listen on port
    listen_addr = f'[::]:{port}'
    actual_port = server.add_insecure_port(listen_addr)

    # Report the actual port back to the Elixir supervisor.
    print(f"GRPC_SERVER_READY_ON_PORT={actual_port}", flush=True)
    
    # Start server
    server.start()
    print(f"gRPC Bridge started on {listen_addr}", file=sys.stderr)
    print(f"Worker type: python-grpc", file=sys.stderr)
    print(f"Supported commands: {len(servicer.command_handler.get_supported_commands() if hasattr(servicer.command_handler, 'get_supported_commands') else [])} commands", file=sys.stderr)
    
    # Handle shutdown gracefully
    def signal_handler(signum, frame):
        print("Shutting down gRPC server...", file=sys.stderr)
        server.stop(grace=5)
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Wait for termination
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        pass


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description='Snakepit gRPC Bridge')
    parser.add_argument('--port', type=int, default=50051, help='Port to listen on')
    parser.add_argument('--adapter', type=str, help='Custom adapter class to use')
    
    args = parser.parse_args()
    
    # Import custom adapter if specified
    adapter_class = None
    if args.adapter:
        # Simple adapter loading - in production would be more sophisticated
        try:
            module_name, class_name = args.adapter.rsplit('.', 1)
            module = __import__(module_name, fromlist=[class_name])
            adapter_class = getattr(module, class_name)
        except Exception as e:
            print(f"Failed to load adapter {args.adapter}: {e}", file=sys.stderr)
            sys.exit(1)
    
    serve(args.port, adapter_class)


if __name__ == '__main__':
    main()