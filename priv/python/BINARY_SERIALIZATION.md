# Binary Serialization Guide

## Overview

The Snakepit bridge automatically uses binary serialization for large tensor and embedding data to improve performance. This guide explains how it works and how to use it effectively.

## Automatic Binary Encoding

When variable data exceeds 10KB (10,240 bytes), the system automatically switches from JSON to binary encoding:

- **Small data (<10KB)**: Uses JSON for readability and debugging
- **Large data (>10KB)**: Uses binary for performance

## Supported Types

Binary serialization is currently available for:
- `tensor`: Multi-dimensional arrays with shape information
- `embedding`: Vector representations (1D arrays)

## Python Usage

### Basic Example

```python
from snakepit_bridge import SessionContext
import numpy as np

class MLAdapter:
    def process_large_data(self, ctx: SessionContext):
        # Create a large tensor (>10KB)
        large_tensor = np.random.randn(100, 100).tolist()  # ~80KB
        
        # This automatically uses binary serialization
        ctx.register_variable("my_tensor", "tensor", {
            "shape": [100, 100],
            "data": large_tensor
        })
        
        # Retrieval is transparent - handles binary automatically
        retrieved = ctx["my_tensor"]
        print(f"Shape: {retrieved['shape']}")
```

### Performance Example

```python
import time

def benchmark_serialization(ctx: SessionContext):
    # Small data - uses JSON
    small_data = list(range(100))  # ~800 bytes
    start = time.time()
    ctx.register_variable("small", "embedding", small_data)
    print(f"Small data: {time.time() - start:.3f}s")
    
    # Large data - uses binary
    large_data = list(range(10000))  # ~80KB
    start = time.time()
    ctx.register_variable("large", "embedding", large_data)
    print(f"Large data: {time.time() - start:.3f}s")
    # Typically 5-10x faster!
```

## Technical Details

### Serialization Format

- **Python side**: Uses `pickle` with highest protocol
- **Elixir side**: Uses Erlang Term Format (ETF)
- **Wire format**: Protocol Buffers with separate binary field

### Threshold Calculation

The 10KB threshold is based on the estimated serialized size:
- For tensors: `len(data) * 8` bytes (assuming float64)
- For embeddings: `len(array) * 8` bytes

### Binary Message Structure

When binary serialization is used:

1. **Metadata** (in `value` field):
   ```json
   {
     "shape": [100, 100],
     "dtype": "float32",
     "binary_format": "pickle",
     "type": "tensor"
   }
   ```

2. **Binary Data** (in `binary_value` field):
   - Pickled Python object containing the actual data

## Best Practices

1. **Use Appropriate Types**: Always use `tensor` or `embedding` types for numerical data
2. **Batch Large Operations**: Group multiple large variables in batch updates
3. **Monitor Memory**: Binary data is held in memory during transfer
4. **Profile Your Data**: Check if your typical data sizes benefit from binary encoding

## Limitations

1. **Type Support**: Only `tensor` and `embedding` types use binary serialization
2. **Debugging**: Binary data is not human-readable in logs
3. **Compatibility**: Binary format is internal - use JSON for external APIs

## Configuration

Currently, the 10KB threshold is not configurable. This value was chosen as optimal for most workloads:
- Keeps small data human-readable
- Maximizes performance for large data
- Minimizes overhead of format detection