#!/usr/bin/env python3
"""
Test adapter for gRPC streaming demo.

This adapter provides streaming command implementations for testing
the gRPC streaming functionality.
"""

import time
from typing import Dict, Any, Iterator

from ..core import BaseCommandHandler


class GRPCStreamingTestHandler(BaseCommandHandler):
    """
    Test command handler that provides streaming operations for demo purposes.
    """
    
    def _register_commands(self):
        """Register all test commands."""
        # Basic commands
        self.register_command("ping", self.handle_ping)
        self.register_command("echo", self.handle_echo)
        # Note: streaming commands are handled by process_stream_command
        
    def handle_ping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Basic ping for non-streaming test."""
        return {
            "status": "ok",
            "timestamp": time.time(),
            "message": "pong"
        }
    
    def handle_echo(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Echo command."""
        return {"echoed": args}
    
    def get_supported_commands(self) -> list:
        """Get all supported commands including streaming ones."""
        basic_commands = super().get_supported_commands()
        streaming_commands = ["ping_stream", "batch_inference", "process_large_dataset", "tail_and_analyze"]
        return basic_commands + streaming_commands
    
    def process_stream_command(self, command: str, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """
        Handle streaming commands.
        
        Yields dictionaries with:
        - data: The chunk data
        - is_final: Boolean indicating if this is the last chunk
        - error: Optional error message
        """
        if command == "ping_stream":
            yield from self._handle_ping_stream(args)
        elif command == "batch_inference":
            yield from self._handle_batch_inference(args)
        elif command == "process_large_dataset":
            yield from self._handle_large_dataset(args)
        elif command == "tail_and_analyze":
            yield from self._handle_log_analysis(args)
        else:
            # Unknown streaming command
            yield {
                "data": {"error": f"Unknown streaming command: {command}"},
                "is_final": True,
                "error": f"Unknown streaming command: {command}"
            }
    
    def _handle_ping_stream(self, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """Stream ping responses."""
        count = args.get('count', 5)
        
        for i in range(count):
            yield {
                "data": {
                    "ping_number": str(i + 1),
                    "timestamp": str(time.time()),
                    "message": f"Ping {i + 1} of {count}"
                },
                "is_final": i == count - 1
            }
    
    def _handle_batch_inference(self, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """Simulate ML batch inference."""
        batch_items = args.get('batch_items', ['item1', 'item2', 'item3'])
        
        for i, item in enumerate(batch_items):
            confidence = 0.85 + (i * 0.05)
            yield {
                "data": {
                    "item": str(item),
                    "prediction": f"class_{i % 3}",
                    "confidence": str(confidence),
                    "processed_at": str(time.time())
                },
                "is_final": i == len(batch_items) - 1
            }
    
    def _handle_large_dataset(self, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """Simulate large dataset processing."""
        total_rows = args.get('total_rows', 1000)
        chunk_size = args.get('chunk_size', 100)
        
        processed = 0
        chunk_num = 0
        
        while processed < total_rows:
            current_chunk_size = min(chunk_size, total_rows - processed)
            processed += current_chunk_size
            progress = (processed / total_rows) * 100
            
            yield {
                "data": {
                    "processed_rows": str(processed),
                    "total_rows": str(total_rows),
                    "progress_percent": f"{progress:.1f}",
                    "chunk_number": str(chunk_num),
                    "chunk_size": str(current_chunk_size)
                },
                "is_final": processed >= total_rows
            }
            
            chunk_num += 1
    
    def _handle_log_analysis(self, args: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        """Simulate log analysis."""
        log_entries = [
            "INFO: Application started",
            "DEBUG: Processing request",
            "ERROR: Database connection failed",
            "WARN: High memory usage detected",
            "INFO: Request completed"
        ]
        
        for i, entry in enumerate(log_entries):
            severity = "ERROR" if "ERROR" in entry else "WARN" if "WARN" in entry else "INFO"
            
            yield {
                "data": {
                    "log_entry": entry,
                    "severity": severity,
                    "timestamp": str(time.time()),
                    "entry_number": str(i + 1)
                },
                "is_final": i == len(log_entries) - 1
            }