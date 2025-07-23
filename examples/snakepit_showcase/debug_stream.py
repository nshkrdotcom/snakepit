#!/usr/bin/env python3
"""Test the stream_progress function directly"""
import sys
sys.path.append('/home/home/p/g/n/dspex/snakepit/priv/python')

from snakepit_bridge.adapters.showcase.handlers.streaming_ops import StreamingOpsHandler

handler = StreamingOpsHandler()
print("Testing stream_progress directly...")

# Call the generator
gen = handler.stream_progress(None, steps=3)
print(f"Generator created: {gen}")
print(f"Is generator: {hasattr(gen, '__iter__')}")

# Consume the generator
for i, chunk in enumerate(gen):
    print(f"Chunk {i}: {chunk}")
    
print("Done!")