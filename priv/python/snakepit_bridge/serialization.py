"""
Type serialization system for Python side of the bridge.
"""

import json
import numpy as np
from typing import Any, Dict, Union
from google.protobuf import any_pb2

class TypeSerializer:
    """Unified type serialization for Python side."""
    
    @staticmethod
    def encode_any(value: Any, var_type: str) -> any_pb2.Any:
        """Encode a Python value to protobuf Any."""
        # Normalize value based on type
        normalized = TypeSerializer._normalize_value(value, var_type)
        
        # Serialize to JSON
        json_str = TypeSerializer._serialize_value(normalized, var_type)
        
        # Create Any message
        any_msg = any_pb2.Any()
        any_msg.type_url = f"dspex.variables/{var_type}"
        any_msg.value = json_str.encode('utf-8')
        
        return any_msg
    
    @staticmethod
    def decode_any(any_msg: any_pb2.Any) -> Any:
        """Decode protobuf Any to Python value."""
        # Extract type from URL
        var_type = any_msg.type_url.split('/')[-1]
        
        # Decode JSON
        json_str = any_msg.value.decode('utf-8')
        value = json.loads(json_str)
        
        # Convert to appropriate Python type
        return TypeSerializer._deserialize_value(value, var_type)
    
    @staticmethod
    def _normalize_value(value: Any, var_type: str) -> Any:
        """Normalize Python values for consistency."""
        if var_type == 'float':
            if isinstance(value, (int, float)):
                return float(value)
            raise ValueError(f"Expected number, got {type(value)}")
            
        elif var_type == 'integer':
            if isinstance(value, (int, float)):
                if isinstance(value, float) and value.is_integer():
                    return int(value)
                elif isinstance(value, int):
                    return value
            raise ValueError(f"Expected integer, got {value}")
            
        elif var_type == 'string':
            return str(value)
            
        elif var_type == 'boolean':
            if isinstance(value, bool):
                return value
            raise ValueError(f"Expected boolean, got {type(value)}")
            
        elif var_type == 'choice':
            return str(value)
            
        elif var_type == 'module':
            return str(value)
            
        elif var_type == 'embedding':
            if isinstance(value, np.ndarray):
                return value.tolist()
            elif isinstance(value, list):
                return [float(x) for x in value]
            raise ValueError(f"Expected array/list, got {type(value)}")
            
        elif var_type == 'tensor':
            if isinstance(value, np.ndarray):
                return {
                    'shape': list(value.shape),
                    'data': value.tolist()
                }
            elif isinstance(value, dict) and 'shape' in value and 'data' in value:
                return value
            raise ValueError(f"Expected tensor, got {type(value)}")
            
        else:
            return value
    
    @staticmethod
    def _serialize_value(value: Any, var_type: str) -> str:
        """Serialize normalized value to JSON string."""
        # Handle special float values
        if var_type == 'float':
            if isinstance(value, float):
                if np.isnan(value):
                    return json.dumps("NaN")
                elif np.isinf(value):
                    return json.dumps("Infinity" if value > 0 else "-Infinity")
        
        return json.dumps(value)
    
    @staticmethod
    def _deserialize_value(value: Any, var_type: str) -> Any:
        """Convert JSON-decoded value to appropriate Python type."""
        if var_type == 'float':
            if value == "NaN":
                return float('nan')
            elif value == "Infinity":
                return float('inf')
            elif value == "-Infinity":
                return float('-inf')
            return float(value)
            
        elif var_type == 'integer':
            return int(value)
            
        elif var_type == 'embedding':
            # Could convert back to numpy array
            return value
            
        elif var_type == 'tensor':
            # Could reconstruct numpy array
            if isinstance(value, dict) and 'data' in value and 'shape' in value:
                data = np.array(value['data'])
                return data.reshape(value['shape'])
            return value
            
        else:
            return value
    
    @staticmethod
    def validate_constraints(value: Any, var_type: str, constraints: Dict) -> None:
        """Validate value against type constraints."""
        if var_type == 'float' or var_type == 'integer':
            min_val = constraints.get('min')
            max_val = constraints.get('max')
            if min_val is not None and value < min_val:
                raise ValueError(f"Value {value} is below minimum {min_val}")
            if max_val is not None and value > max_val:
                raise ValueError(f"Value {value} is above maximum {max_val}")
                
        elif var_type == 'string':
            min_len = constraints.get('min_length', 0)
            max_len = constraints.get('max_length')
            length = len(value)
            if length < min_len:
                raise ValueError(f"String too short: {length} < {min_len}")
            if max_len and length > max_len:
                raise ValueError(f"String too long: {length} > {max_len}")
                
        elif var_type == 'choice':
            choices = constraints.get('choices', [])
            if choices and value not in choices:
                raise ValueError(f"Value {value} not in allowed choices: {choices}")
                
        elif var_type == 'module':
            allowed_modules = constraints.get('allowed_modules', [])
            if allowed_modules and value not in allowed_modules:
                raise ValueError(f"Module {value} not in allowed modules: {allowed_modules}")
                
        elif var_type == 'embedding':
            dimensions = constraints.get('dimensions')
            if dimensions and len(value) != dimensions:
                raise ValueError(f"Wrong dimensions: {len(value)} != {dimensions}")
                
        elif var_type == 'tensor':
            expected_shape = constraints.get('shape')
            if expected_shape:
                actual_shape = value.get('shape') if isinstance(value, dict) else list(value.shape)
                if actual_shape != expected_shape:
                    raise ValueError(f"Wrong shape: {actual_shape} != {expected_shape}")