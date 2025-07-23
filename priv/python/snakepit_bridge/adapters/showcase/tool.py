"""Simple Tool wrapper for showcase adapter."""

class Tool:
    """Simple wrapper for tool functions."""
    def __init__(self, func):
        self.func = func
        self.name = func.__name__
    
    def __call__(self, *args, **kwargs):
        return self.func(*args, **kwargs)

class StreamChunk:
    """Simple stream chunk wrapper."""
    def __init__(self, data, is_final=False):
        self.data = data
        self.is_final = is_final