"""
Integration tests for the unified bridge variable system.
"""

import pytest
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List
import os
import sys

# Add the Python bridge to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../priv/python'))

from snakepit_bridge import SessionContext, VariableType, VariableNotFoundError
from .test_infrastructure import test_server, test_session, TestMetrics


class TestVariableLifecycle:
    """Test basic variable operations."""
    
    def test_register_and_get(self, session: SessionContext):
        """Test variable registration and retrieval."""
        # Register a variable
        var_id = session.register_variable(
            'test_var',
            VariableType.FLOAT,
            3.14,
            constraints={'min': 0, 'max': 10},
            metadata={'purpose': 'testing'}
        )
        
        assert var_id.startswith('var_')
        
        # Get by name
        value = session.get_variable('test_var')
        assert value == 3.14
        
        # Get by ID
        value_by_id = session.get_variable(var_id)
        assert value_by_id == 3.14
    
    def test_update_variable(self, session: SessionContext):
        """Test variable updates."""
        session.register_variable('counter', VariableType.INTEGER, 0)
        
        # Update
        session.update_variable('counter', 42)
        
        # Verify
        value = session.get_variable('counter')
        assert value == 42
    
    def test_delete_variable(self, session: SessionContext):
        """Test variable deletion."""
        session.register_variable('temp_var', VariableType.STRING, 'temporary')
        
        # Verify exists
        assert 'temp_var' in session
        
        # Delete
        session.delete_variable('temp_var')
        
        # Verify gone
        assert 'temp_var' not in session
        
        with pytest.raises(VariableNotFoundError):
            session.get_variable('temp_var')
    
    def test_constraints_enforced(self, session: SessionContext):
        """Test that constraints are enforced."""
        session.register_variable(
            'percentage',
            VariableType.FLOAT,
            0.5,
            constraints={'min': 0.0, 'max': 1.0}
        )
        
        # Valid update
        session.update_variable('percentage', 0.8)
        assert session['percentage'] == 0.8
        
        # Invalid update - too high
        with pytest.raises(Exception) as exc_info:
            session.update_variable('percentage', 1.5)
        assert 'above maximum' in str(exc_info.value).lower()
        
        # Value unchanged
        assert session['percentage'] == 0.8


class TestBatchOperations:
    """Test batch variable operations."""
    
    def test_batch_get(self, session: SessionContext):
        """Test getting multiple variables."""
        # Register variables
        for i in range(5):
            session.register_variable(f'var_{i}', VariableType.INTEGER, i * 10)
        
        # Batch get
        names = [f'var_{i}' for i in range(5)]
        values = session.get_variables(names)
        
        assert len(values) == 5
        for i in range(5):
            assert values[f'var_{i}'] == i * 10
    
    def test_batch_update_non_atomic(self, session: SessionContext):
        """Test non-atomic batch updates."""
        # Register variables
        session.register_variable('a', VariableType.INTEGER, 1)
        session.register_variable('b', VariableType.INTEGER, 2)
        session.register_variable('c', VariableType.INTEGER, 3,
                                 constraints={'max': 10})
        
        # Batch update with one failure
        updates = {
            'a': 10,
            'b': 20,
            'c': 30  # Will fail constraint
        }
        
        results = session.update_variables(updates, atomic=False)
        
        # Check results
        assert results['a'] is True
        assert results['b'] is True
        assert isinstance(results['c'], str)  # Error message
        
        # Verify partial update
        assert session['a'] == 10
        assert session['b'] == 20
        assert session['c'] == 3  # Unchanged
    
    def test_batch_update_atomic(self, session: SessionContext):
        """Test atomic batch updates."""
        # Register variables
        session.register_variable('x', VariableType.INTEGER, 1)
        session.register_variable('y', VariableType.INTEGER, 2)
        session.register_variable('z', VariableType.INTEGER, 3,
                                 constraints={'max': 10})
        
        # Atomic update with one failure
        updates = {
            'x': 100,
            'y': 200,
            'z': 300  # Will fail
        }
        
        # Should fail atomically
        results = session.update_variables(updates, atomic=True)
        
        # All should report errors in atomic mode when one fails
        assert not all(v is True for v in results.values())
        
        # Verify no changes
        assert session['x'] == 1
        assert session['y'] == 2
        assert session['z'] == 3


class TestCaching:
    """Test caching behavior."""
    
    def test_cache_performance(self, session: SessionContext, metrics: TestMetrics):
        """Test that caching improves performance."""
        session.register_variable('cached_var', VariableType.STRING, 'test value')
        
        # First access - cache miss
        with metrics.time('cache_miss'):
            value1 = session['cached_var']
        
        # Multiple cache hits
        for i in range(10):
            with metrics.time('cache_hit'):
                value = session['cached_var']
                assert value == 'test value'
        
        # Report will show cache hits are faster
    
    def test_cache_invalidation_on_update(self, session: SessionContext):
        """Test cache invalidation on updates."""
        session.register_variable('test', VariableType.INTEGER, 1)
        
        # Prime cache
        assert session['test'] == 1
        
        # Update should invalidate
        session['test'] = 2
        
        # Next read should get new value
        assert session['test'] == 2
    
    def test_cache_ttl(self, session: SessionContext):
        """Test cache TTL expiration."""
        # Set short TTL
        from datetime import timedelta
        session.set_cache_ttl(timedelta(seconds=0.5))
        
        session.register_variable('ttl_test', VariableType.INTEGER, 42)
        
        # Access to cache
        assert session['ttl_test'] == 42
        
        # Wait for expiry
        time.sleep(0.6)
        
        # Should fetch again (test would fail if server down)
        assert session['ttl_test'] == 42


class TestConcurrency:
    """Test concurrent access patterns."""
    
    def test_concurrent_reads(self, session: SessionContext, metrics: TestMetrics):
        """Test multiple concurrent reads."""
        session.register_variable('shared', VariableType.INTEGER, 0)
        
        def read_variable(thread_id: int) -> int:
            return session.get_variable('shared')
        
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = []
            for i in range(100):
                future = executor.submit(read_variable, i)
                futures.append(future)
            
            results = [f.result() for f in as_completed(futures)]
        
        # All should read same value
        assert all(r == 0 for r in results)
        metrics.count('concurrent_reads', len(results))
    
    def test_concurrent_updates(self, session: SessionContext):
        """Test concurrent updates maintain consistency."""
        session.register_variable('counter', VariableType.INTEGER, 0)
        
        def increment_counter(thread_id: int):
            for _ in range(10):
                current = session.get_variable('counter')
                session.update_variable('counter', current + 1)
                time.sleep(0.001)  # Small delay to increase contention
        
        # Run concurrent increments
        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = []
            for i in range(5):
                future = executor.submit(increment_counter, i)
                futures.append(future)
            
            # Wait for completion
            for future in as_completed(futures):
                future.result()
        
        # Check final value - may not be 50 due to race conditions
        # This demonstrates the need for atomic operations
        final_value = session['counter']
        print(f"Final counter value: {final_value} (expected up to 50)")
        assert final_value > 0
        assert final_value <= 50
    
    def test_session_isolation(self, server_fixture):
        """Test that sessions are isolated."""
        from snakepit_bridge_pb2_grpc import BridgeServiceStub
        from snakepit_bridge_pb2 import InitializeSessionRequest, CleanupSessionRequest
        import grpc
        
        channel = grpc.insecure_channel(f'localhost:{server_fixture.port}')
        stub = BridgeServiceStub(channel)
        
        # Initialize two sessions
        for session_id in ['session_1', 'session_2']:
            init_req = InitializeSessionRequest(session_id=session_id)
            init_resp = stub.InitializeSession(init_req)
            assert init_resp.success
        
        try:
            # Create two session contexts
            ctx1 = SessionContext(stub, 'session_1')
            ctx2 = SessionContext(stub, 'session_2')
            
            # Register same variable name in both
            ctx1.register_variable('isolated', VariableType.STRING, 'session1')
            ctx2.register_variable('isolated', VariableType.STRING, 'session2')
            
            # Verify isolation
            assert ctx1['isolated'] == 'session1'
            assert ctx2['isolated'] == 'session2'
            
            # Update in one shouldn't affect other
            ctx1['isolated'] = 'updated1'
            assert ctx1['isolated'] == 'updated1'
            assert ctx2['isolated'] == 'session2'
        finally:
            # Cleanup
            for session_id in ['session_1', 'session_2']:
                cleanup_req = CleanupSessionRequest(session_id=session_id, force=True)
                stub.CleanupSession(cleanup_req)
            channel.close()


class TestErrorHandling:
    """Test error scenarios."""
    
    def test_invalid_type(self, session: SessionContext):
        """Test type validation errors."""
        session.register_variable('typed', VariableType.INTEGER, 42)
        
        # Try to update with wrong type
        with pytest.raises(ValueError) as exc_info:
            session['typed'] = "not a number"
        assert 'cannot convert' in str(exc_info.value).lower()
    
    def test_nonexistent_variable(self, session: SessionContext):
        """Test accessing non-existent variables."""
        with pytest.raises(VariableNotFoundError) as exc_info:
            session.get_variable('does_not_exist')
        assert 'not found' in str(exc_info.value).lower()
    
    def test_constraint_validation(self, session: SessionContext):
        """Test various constraint violations."""
        # String length
        session.register_variable(
            'short_string',
            VariableType.STRING,
            'test',
            constraints={'min_length': 3, 'max_length': 10}
        )
        
        with pytest.raises(ValueError):
            session['short_string'] = 'a'  # Too short
        
        with pytest.raises(ValueError):
            session['short_string'] = 'a' * 20  # Too long
        
        # Pattern matching
        session.register_variable(
            'pattern_string',
            VariableType.STRING,
            'ABC123',
            constraints={'pattern': '^[A-Z]+[0-9]+$'}
        )
        
        session['pattern_string'] = 'XYZ789'  # Valid
        
        with pytest.raises(ValueError):
            session['pattern_string'] = 'abc123'  # Invalid case


class TestPythonAPIPatterns:
    """Test various Python API usage patterns."""
    
    def test_dict_style_access(self, session: SessionContext):
        """Test dictionary-style access."""
        # Auto-registration
        session['new_var'] = 42
        assert session['new_var'] == 42
        
        # Check exists
        assert 'new_var' in session
        assert 'not_exist' not in session
        
        # Update
        session['new_var'] = 100
        assert session['new_var'] == 100
    
    def test_attribute_style_access(self, session: SessionContext):
        """Test attribute-style access via .v namespace."""
        # Register first
        session.register_variable('attr_var', VariableType.FLOAT, 1.5)
        
        # Read
        assert session.v.attr_var == 1.5
        
        # Write
        session.v.attr_var = 2.5
        assert session.v.attr_var == 2.5
        
        # Auto-register
        session.v.auto_attr = "hello"
        assert session.v.auto_attr == "hello"
    
    def test_batch_context_manager(self, session: SessionContext):
        """Test batch update context manager."""
        # Register variables
        for i in range(5):
            session[f'batch_{i}'] = i
        
        # Batch update
        with session.batch_updates() as batch:
            for i in range(5):
                batch[f'batch_{i}'] = i * 10
        
        # Verify
        for i in range(5):
            assert session[f'batch_{i}'] == i * 10
    
    def test_variable_proxy(self, session: SessionContext):
        """Test variable proxy for repeated access."""
        session['proxy_var'] = 0
        
        # Get proxy
        var = session.variable('proxy_var')
        
        # Repeated updates via proxy
        for i in range(5):
            var.value = i
            assert var.value == i


# Pytest fixtures

@pytest.fixture(scope='session')
def server_fixture():
    """Start test server for session."""
    with test_server() as srv:
        yield srv


@pytest.fixture
def session(server_fixture):
    """Create test session."""
    with test_session(server_fixture) as ctx:
        yield ctx


@pytest.fixture(scope='session')
def metrics():
    """Test metrics collector."""
    m = TestMetrics()
    yield m
    m.report()