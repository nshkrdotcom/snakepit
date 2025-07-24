#!/usr/bin/env python3
"""
Example usage of the enhanced SessionContext with variable support.
"""

import grpc
import time
from snakepit_bridge import SessionContext, VariableType
from snakepit_bridge_pb2_grpc import BridgeServiceStub


def basic_usage(ctx: SessionContext):
    """Basic variable operations."""
    print("\n=== Basic Variable Usage ===")
    
    # Register variables
    temp_id = ctx.register_variable('temperature', VariableType.FLOAT, 0.7,
                                   constraints={'min': 0.0, 'max': 2.0})
    print(f"Registered temperature variable with ID: {temp_id}")
    
    tokens_id = ctx.register_variable('max_tokens', VariableType.INTEGER, 100,
                                     constraints={'min': 1, 'max': 1000})
    print(f"Registered max_tokens variable with ID: {tokens_id}")
    
    model_id = ctx.register_variable('model_name', VariableType.STRING, 'gpt-3.5-turbo',
                                    constraints={'enum': ['gpt-3.5-turbo', 'gpt-4']})
    print(f"Registered model_name variable with ID: {model_id}")
    
    # Get values
    temp = ctx.get_variable('temperature')
    print(f"Temperature: {temp}")
    
    # Update values
    ctx.update_variable('temperature', 0.9)
    print("Updated temperature to 0.9")
    
    # Dict-style access
    ctx['max_tokens'] = 200
    print(f"Max tokens (dict access): {ctx['max_tokens']}")
    
    # Attribute-style access
    ctx.v.temperature = 0.8
    print(f"Temperature (attribute access): {ctx.v.temperature}")


def batch_operations(ctx: SessionContext):
    """Efficient batch operations."""
    print("\n=== Batch Operations ===")
    
    # Register multiple variables
    for i in range(5):
        ctx.register_variable(f'param_{i}', VariableType.FLOAT, i * 0.1)
    print("Registered 5 parameter variables")
    
    # Batch get
    names = [f'param_{i}' for i in range(5)]
    values = ctx.get_variables(names)
    print(f"Batch get values: {values}")
    
    # Batch update
    print("Performing batch update...")
    with ctx.batch_updates() as batch:
        for i in range(5):
            batch[f'param_{i}'] = i * 0.2
    
    # Verify updates
    new_values = ctx.get_variables(names)
    print(f"Updated values: {new_values}")


def cache_demonstration(ctx: SessionContext):
    """Show caching behavior."""
    print("\n=== Cache Demonstration ===")
    
    ctx.register_variable('cached_var', VariableType.INTEGER, 42)
    
    # First access - cache miss
    start = time.time()
    value1 = ctx['cached_var']
    time1 = time.time() - start
    print(f"First access (cache miss): {time1:.4f}s, value={value1}")
    
    # Second access - cache hit
    start = time.time()
    value2 = ctx['cached_var']
    time2 = time.time() - start
    print(f"Second access (cache hit): {time2:.4f}s, value={value2}")
    
    if time2 > 0:
        print(f"Cache speedup: {time1/time2:.1f}x")
    
    # Wait for cache expiry
    print("Waiting 6 seconds for cache expiry...")
    time.sleep(6)
    
    # Third access - cache miss again
    start = time.time()
    value3 = ctx['cached_var']
    time3 = time.time() - start
    print(f"Third access (cache expired): {time3:.4f}s, value={value3}")


def variable_proxy_usage(ctx: SessionContext):
    """Use variable proxies for repeated access."""
    print("\n=== Variable Proxy Usage ===")
    
    ctx.register_variable('counter', VariableType.INTEGER, 0)
    
    # Get a proxy
    counter = ctx.variable('counter')
    
    # Repeated access through proxy
    print("Incrementing counter through proxy:")
    for i in range(5):
        current = counter.value
        counter.value = current + 1
        print(f"  Counter: {counter.value}")


def auto_registration(ctx: SessionContext):
    """Demonstrate auto-registration of variables."""
    print("\n=== Auto-Registration ===")
    
    # Setting a non-existent variable auto-registers it
    ctx['auto_float'] = 3.14
    print(f"Auto-registered float: {ctx['auto_float']}")
    
    # Type is inferred
    ctx['auto_int'] = 42
    ctx['auto_str'] = "hello"
    ctx['auto_bool'] = True
    
    print("Auto-registered variables with inferred types:")
    print(f"  auto_int: {ctx['auto_int']} (inferred as integer)")
    print(f"  auto_str: {ctx['auto_str']} (inferred as string)")
    print(f"  auto_bool: {ctx['auto_bool']} (inferred as boolean)")


def constraint_validation(ctx: SessionContext):
    """Demonstrate constraint validation."""
    print("\n=== Constraint Validation ===")
    
    # Register with constraints
    ctx.register_variable('constrained_float', VariableType.FLOAT, 0.5,
                         constraints={'min': 0.0, 'max': 1.0})
    
    # Valid update
    try:
        ctx['constrained_float'] = 0.7
        print(f"Valid update succeeded: {ctx['constrained_float']}")
    except Exception as e:
        print(f"Valid update failed: {e}")
    
    # Invalid update
    try:
        ctx['constrained_float'] = 1.5
        print(f"Invalid update succeeded: {ctx['constrained_float']}")
    except Exception as e:
        print(f"Invalid update failed (expected): {e}")


def main():
    """Run all examples."""
    # Connect to gRPC server
    channel = grpc.insecure_channel('localhost:50051')
    stub = BridgeServiceStub(channel)
    
    # Create session context
    session_id = f"example_session_{int(time.time())}"
    ctx = SessionContext(stub, session_id)
    
    print(f"Created session: {session_id}")
    
    try:
        # Run examples
        basic_usage(ctx)
        batch_operations(ctx)
        cache_demonstration(ctx)
        variable_proxy_usage(ctx)
        auto_registration(ctx)
        constraint_validation(ctx)
        
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # Clear cache before exit
        ctx.clear_cache()
        print("\nExamples completed!")


if __name__ == '__main__':
    main()