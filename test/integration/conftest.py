"""
Pytest configuration for integration tests.
"""

import pytest
import os
import sys

# Add the Python bridge to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../priv/python'))

# Configure pytest
def pytest_configure(config):
    """Configure pytest with custom markers."""
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
    config.addinivalue_line(
        "markers", "benchmark: marks tests as benchmarks"
    )
    config.addinivalue_line(
        "markers", "integration: marks tests as integration tests"
    )
    config.addinivalue_line(
        "markers", "requires_server: marks tests that require a running gRPC server"
    )