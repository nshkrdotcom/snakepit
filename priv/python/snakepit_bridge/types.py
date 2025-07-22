"""
Type system support for the unified bridge variable system.

Provides type validation, serialization, and constraint checking for
all supported variable types.
"""

from enum import Enum
from typing import Any, Dict, Type, Union
import json
import struct
from google.protobuf.any_pb2 import Any as ProtoAny

from .grpc import snakepit_bridge_pb2 as pb2


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
        elif isinstance(value, int):
            return VariableType.INTEGER
        elif isinstance(value, float):
            return VariableType.FLOAT
        else:
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


def serialize_value(value: Any, var_type: VariableType) -> ProtoAny:
    """Serialize a value to protobuf Any."""
    # Special handling for float values
    if var_type == VariableType.FLOAT:
        if isinstance(value, float):
            import math
            if math.isnan(value):
                json_value = "NaN"
            elif math.isinf(value):
                json_value = "Infinity" if value > 0 else "-Infinity"
            else:
                json_value = value
        else:
            json_value = value
    else:
        json_value = value
    
    data = json.dumps(json_value)
    
    return ProtoAny(
        type_url=f"type.googleapis.com/snakepit.{var_type.value}",
        value=data.encode('utf-8')
    )


def deserialize_value(proto_any: ProtoAny, expected_type: VariableType) -> Any:
    """Deserialize a value from protobuf Any."""
    try:
        json_str = proto_any.value.decode('utf-8')
        value = json.loads(json_str)
        
        # Handle special float values
        if expected_type == VariableType.FLOAT:
            if value == "NaN":
                return float('nan')
            elif value == "Infinity":
                return float('inf')
            elif value == "-Infinity":
                return float('-inf')
        
        return value
    except Exception as e:
        # Fallback to raw value
        return proto_any.value.decode('utf-8')


def validate_constraints(value: Any, var_type: VariableType, constraints: Dict[str, Any]) -> None:
    """Validate a value against type constraints."""
    validator = TypeValidator.get_validator(var_type)
    validator.validate_constraints(value, constraints)