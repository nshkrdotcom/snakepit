"""Binary operations handler for showcase adapter."""

import numpy as np
import time
from typing import Dict, Any, List
from ..tool import Tool


class BinaryOpsHandler:
    """Handler for binary serialization demonstrations."""
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "create_tensor": Tool(self.create_tensor),
            "create_embedding": Tool(self.create_embedding),
            "benchmark_encoding": Tool(self.benchmark_encoding),
        }
    
    def create_tensor(self, ctx, name: str, shape: List[int], 
                     size_bytes: int = None) -> Dict[str, Any]:
        """Create a tensor and demonstrate encoding detection."""
        # Calculate elements needed for target size
        if size_bytes:
            # Each float64 is 8 bytes
            total_elements = size_bytes // 8
            # Adjust shape to meet size requirement
            if len(shape) == 2:
                shape[0] = int(total_elements // shape[1])
        
        # Ensure shape contains only integers
        shape = [int(s) for s in shape]
        
        # Create tensor
        data = np.random.randn(*shape)
        actual_bytes = data.nbytes
        
        # The system automatically chooses encoding
        # JSON for < 10KB, binary for >= 10KB
        encoding = "binary" if actual_bytes >= 10240 else "json"
        
        # In production, this would use ctx.register_variable()
        # For demo, we just report the tensor was created
        
        return {
            "name": name,
            "shape": shape,
            "size_bytes": actual_bytes,
            "encoding": encoding,
            "elements": data.size
        }
    
    def create_embedding(self, ctx, text: str, dimensions: int) -> Dict[str, Any]:
        """Create an embedding (float vector) from text."""
        # Simulate text embedding
        # In real usage, this would use an actual embedding model
        
        # Create pseudo-random embedding based on text
        seed = sum(ord(c) for c in text)
        np.random.seed(seed % 2**32)
        embedding = np.random.randn(dimensions)
        
        # Normalize to unit vector (common for embeddings)
        embedding = embedding / np.linalg.norm(embedding)
        
        # In production, this would use ctx.register_variable()
        # For demo, we simulate the storage
        
        size_bytes = embedding.nbytes
        encoding = "binary" if size_bytes >= 10240 else "json"
        
        return {
            "text": text,
            "dimensions": dimensions,
            "encoding": encoding,
            "size_bytes": size_bytes,
            "norm": float(np.linalg.norm(embedding))
        }
    
    def benchmark_encoding(self, ctx, start_kb: int = 1, end_kb: int = 100,
                          step_kb: int = 10) -> Dict[str, Any]:
        """Benchmark JSON vs binary encoding thresholds."""
        results = []
        
        for size_kb in range(start_kb, end_kb + 1, step_kb):
            size_bytes = size_kb * 1024
            elements = size_bytes // 8  # float64
            
            # Create data
            data = np.random.randn(elements)
            
            # Measure JSON encoding time
            start = time.time()
            json_data = data.tolist()
            json_time = time.time() - start
            
            # Simulate binary encoding time (much faster)
            start = time.time()
            binary_data = data.tobytes()
            binary_time = time.time() - start
            
            results.append({
                "size_kb": size_kb,
                "encoding": "binary" if size_bytes >= 10240 else "json",
                "json_time_ms": round(json_time * 1000, 2),
                "binary_time_ms": round(binary_time * 1000, 2),
                "speedup": round(json_time / binary_time, 1)
            })
        
        return {"results": results}