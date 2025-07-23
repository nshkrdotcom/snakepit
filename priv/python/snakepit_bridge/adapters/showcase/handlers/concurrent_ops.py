"""Concurrent operations handler for showcase adapter."""

import time
import os
import psutil
from typing import Dict, Any
from ..tool import Tool


class ConcurrentOpsHandler:
    """Handler for concurrent operations demonstrations."""
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "cpu_bound_task": Tool(self.cpu_bound_task),
            "sleep_task": Tool(self.sleep_task),
            "lightweight_task": Tool(self.lightweight_task),
            "get_pool_stats": Tool(self.get_pool_stats),
        }
    
    def cpu_bound_task(self, ctx, task_id: str, 
                      duration_ms: int) -> Dict[str, Any]:
        """Simulate CPU-bound work."""
        start_time = time.time()
        
        # Simulate work
        result = 0
        iterations = duration_ms * 1000  # Adjust for CPU speed
        for i in range(iterations):
            result += i ** 2
        
        actual_duration = (time.time() - start_time) * 1000
        
        return {
            "task_id": task_id,
            "result": result % 1000000,  # Keep manageable
            "actual_duration_ms": round(actual_duration, 2)
        }
    
    def sleep_task(self, ctx, duration_ms: int, 
                   task_number: int) -> Dict[str, Any]:
        """Simple sleep task."""
        time.sleep(duration_ms / 1000.0)
        return {
            "task_number": task_number,
            "slept_ms": duration_ms
        }
    
    def lightweight_task(self, ctx, iteration: int) -> Dict[str, Any]:
        """Very lightweight task for benchmarking."""
        return {
            "iteration": iteration,
            "result": iteration * 2
        }
    
    def get_pool_stats(self, ctx) -> Dict[str, Any]:
        """Get current pool statistics."""
        process = psutil.Process(os.getpid())
        memory_mb = process.memory_info().rss / 1024 / 1024
        
        return {
            "worker_pid": os.getpid(),
            "memory_mb": round(memory_mb, 2),
            "cpu_percent": process.cpu_percent()
        }