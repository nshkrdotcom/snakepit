"""Streaming operations handler for showcase adapter."""

import numpy as np
import time
from datetime import datetime
from typing import Dict, Any
from ..tool import Tool, StreamChunk


class StreamingOpsHandler:
    """Handler for streaming operations demonstrations."""
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "stream_progress": Tool(self.stream_progress),
            "stream_fibonacci": Tool(self.stream_fibonacci),
            "generate_dataset": Tool(self.generate_dataset),
            "infinite_stream": Tool(self.infinite_stream),
        }
    
    def stream_progress(
        self,
        ctx,
        steps: int = 10,
        delay_ms: int = 500,
    ) -> StreamChunk:
        """Demonstrate streaming with progress updates and configurable pacing."""
        delay_seconds = max(delay_ms, 0) / 1000.0
        start = time.perf_counter()

        for i in range(steps):
            progress = (i + 1) / steps * 100
            elapsed_ms = (time.perf_counter() - start) * 1000.0

            yield StreamChunk({
                "step": i + 1,
                "total": steps,
                "progress": round(progress, 1),
                "message": f"Processing step {i + 1}/{steps}",
                "elapsed_ms": round(elapsed_ms, 1)
            }, is_final=(i == steps - 1))
            if i < steps - 1 and delay_seconds > 0:
                time.sleep(delay_seconds)
    
    def stream_fibonacci(self, ctx, count: int = 20) -> StreamChunk:
        """Stream Fibonacci sequence."""
        a, b = 0, 1
        for i in range(count):
            yield StreamChunk({
                "index": i + 1,
                "value": a
            }, is_final=(i == count - 1))
            a, b = b, a + b
            time.sleep(0.05)
    
    def generate_dataset(self, ctx, rows: int = 1000, 
                        chunk_size: int = 100) -> StreamChunk:
        """Generate and stream a large dataset."""
        total_sent = 0
        while total_sent < rows:
            rows_in_chunk = min(chunk_size, rows - total_sent)
            total_sent += rows_in_chunk
            
            # Generate some dummy data
            data = np.random.randn(rows_in_chunk, 10)
            
            yield StreamChunk({
                "rows_in_chunk": rows_in_chunk,
                "total_rows": total_sent,
                "data_sample": data[0].tolist()  # Just first row as sample
            }, is_final=(total_sent >= rows))
            
            time.sleep(0.1)
    
    def infinite_stream(self, ctx, delay_ms: int = 500) -> StreamChunk:
        """Infinite stream for testing cancellation."""
        counter = 0
        while True:
            counter += 1
            yield StreamChunk({
                "message": f"Message #{counter}",
                "timestamp": datetime.now().isoformat()
            }, is_final=False)
            time.sleep(delay_ms / 1000.0)
