"""
Type system support for the unified bridge variable system.

Provides type validation, serialization, and constraint checking for
all supported variable types.
"""

from enum import Enum
from typing import Any, Dict, Type, Union, Tuple, Optional
import json
import struct
from google.protobuf.any_pb2 import Any as ProtoAny

from .grpc import snakepit_bridge_pb2 as pb2
from .serialization import TypeSerializer


class VariableType(Enum):
    """Variable types matching the protobuf definition."""
    FLOAT = "float"
    INTEGER = "integer"
    STRING = "string"
    BOOLEAN = "boolean"
    CHOICE = "choice"
    MODULE = "module"
    EMBEDDING = "embedding"
    TENSOR = "tensor"
    MAP = "map"      # Add this
    LIST = "list"    # Add this
    
    def to_proto(self) -> str:
        """Convert to protobuf string representation."""
        return self.value
    
    @classmethod
    def from_proto(cls, proto_type: str) -> 'VariableType':
        """Create from protobuf string representation."""
        try:
            return cls(proto_type.lower())
        except ValueError:
            # Default to string for unknown types
            return cls.STRING


class TypeValidator:
    """Base class for type validators."""
    
    @staticmethod
    def validate(value: Any) -> Any:
        """Validate and potentially convert value."""
        raise NotImplementedError
    
    @staticmethod
    def validate_constraints(value: Any, constraints: Dict[str, Any]) -> None:
        """Validate value against constraints."""
        pass
    
    @classmethod
    def get_validator(cls, var_type: VariableType) -> Type['TypeValidator']:
        """Get validator for a type."""
        validators = {
            VariableType.FLOAT: FloatValidator,
            VariableType.INTEGER: IntegerValidator,
            VariableType.STRING: StringValidator,
            VariableType.BOOLEAN: BooleanValidator,
        }
        return validators.get(var_type, StringValidator)
    
    @classmethod
    def infer_type(cls, value: Any) -> VariableType:
        """Infer type from a Python value."""
        if isinstance(value, bool):
            return VariableType.BOOLEAN
        if isinstance(value, int):
            return VariableType.INTEGER
        if isinstance(value, float):
            return VariableType.FLOAT
        if isinstance(value, str):
            return VariableType.STRING
        # CORRECT: Add checks for dict and list *before* the string fallback
        if isinstance(value, dict):
            return VariableType.MAP
        if isinstance(value, list):
            return VariableType.LIST
            
        # Default to string for any other unknown types
        return VariableType.STRING


class FloatValidator(TypeValidator):
    """Validator for float type."""
    
    @staticmethod
    def validate(value: Any) -> float:
        if isinstance(value, (int, float)):
            return float(value)
        elif isinstance(value, str):
            if value in ('inf', 'Infinity'):
                return float('inf')
            elif value in ('-inf', '-Infinity'):
                return float('-inf')
            elif value in ('nan', 'NaN'):
                return float('nan')
            else:
                try:
                    return float(value)
                except ValueError:
                    raise ValueError(f"Cannot convert '{value}' to float")
        else:
            raise ValueError(f"Cannot convert {type(value).__name__} to float")
    
    @staticmethod
    def validate_constraints(value: float, constraints: Dict[str, Any]) -> None:
        if 'min' in constraints and value < constraints['min']:
            raise ValueError(f"Value {value} below minimum {constraints['min']}")
        if 'max' in constraints and value > constraints['max']:
            raise ValueError(f"Value {value} above maximum {constraints['max']}")


class IntegerValidator(TypeValidator):
    """Validator for integer type."""
    
    @staticmethod
    def validate(value: Any) -> int:
        if isinstance(value, bool):
            raise ValueError("Boolean cannot be converted to integer")
        elif isinstance(value, int):
            return value
        elif isinstance(value, float):
            if value.is_integer():
                return int(value)
            else:
                raise ValueError(f"Float {value} is not a whole number")
        elif isinstance(value, str):
            try:
                return int(value)
            except ValueError:
                raise ValueError(f"Cannot convert '{value}' to integer")
        else:
            raise ValueError(f"Cannot convert {type(value).__name__} to integer")
    
    @staticmethod
    def validate_constraints(value: int, constraints: Dict[str, Any]) -> None:
        if 'min' in constraints and value < constraints['min']:
            raise ValueError(f"Value {value} below minimum {constraints['min']}")
        if 'max' in constraints and value > constraints['max']:
            raise ValueError(f"Value {value} above maximum {constraints['max']}")


class StringValidator(TypeValidator):
    """Validator for string type."""
    
    @staticmethod
    def validate(value: Any) -> str:
        return str(value)
    
    @staticmethod
    def validate_constraints(value: str, constraints: Dict[str, Any]) -> None:
        length = len(value)
        if 'min_length' in constraints and length < constraints['min_length']:
            raise ValueError(f"String too short: {length} < {constraints['min_length']}")
        if 'max_length' in constraints and length > constraints['max_length']:
            raise ValueError(f"String too long: {length} > {constraints['max_length']}")
        if 'pattern' in constraints:
            import re
            if not re.match(constraints['pattern'], value):
                raise ValueError(f"String doesn't match pattern: {constraints['pattern']}")
        if 'enum' in constraints and value not in constraints['enum']:
            raise ValueError(f"Value must be one of: {constraints['enum']}")


class BooleanValidator(TypeValidator):
    """Validator for boolean type."""
    
    @staticmethod
    def validate(value: Any) -> bool:
        if isinstance(value, bool):
            return value
        elif isinstance(value, str):
            if value.lower() == 'true':
                return True
            elif value.lower() == 'false':
                return False
            else:
                raise ValueError(f"Cannot convert '{value}' to boolean")
        elif isinstance(value, int):
            if value == 1:
                return True
            elif value == 0:
                return False
            else:
                raise ValueError(f"Cannot convert {value} to boolean")
        else:
            raise ValueError(f"Cannot convert {type(value).__name__} to boolean")


def serialize_value(value: Any, var_type: VariableType) -> Tuple[ProtoAny, Optional[bytes]]:
    """
    Serialize a value to protobuf Any with optional binary data.
    
    Returns:
        Tuple of (Any message, optional binary data)
    """
    # Delegate to TypeSerializer which handles binary serialization
    return TypeSerializer.encode_any(value, var_type.value)


def deserialize_value(proto_any: ProtoAny, expected_type: VariableType, binary_data: Optional[bytes] = None) -> Any:
    """
    Deserialize a value from protobuf Any with optional binary data.
    
    Args:
        proto_any: Protobuf Any message
        expected_type: Expected variable type
        binary_data: Optional binary data for large values
        
    Returns:
        Deserialized value
    """
    # Delegate to TypeSerializer which handles binary deserialization
    return TypeSerializer.decode_any(proto_any, binary_data)


def validate_constraints(value: Any, var_type: VariableType, constraints: Dict[str, Any]) -> None:
    """Validate a value against type constraints."""
    validator = TypeValidator.get_validator(var_type)
    validator.validate_constraints(value, constraints)