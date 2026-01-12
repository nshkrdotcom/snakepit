"""
Type serialization system for Python side of the bridge.

Supports both JSON and binary serialization for efficient handling
of large numerical data like tensors and embeddings.

Graceful Serialization Policy
-----------------------------
When encountering non-serializable objects, the serializer creates a marker.
By default, the marker only includes type info (safe). The repr can be
optionally included via environment variables:

    SNAKEPIT_UNSERIALIZABLE_DETAIL:
        none (default)         - Only type, no repr (safe for production)
        type                   - Placeholder string with type name
        repr_truncated         - Include truncated repr (may leak secrets)
        repr_redacted_truncated - Truncated repr with common secrets redacted

    SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN:
        Maximum length for repr strings (default: 500, max: 2000)
"""

# Try to import orjson for 6x performance boost, fallback to stdlib json
try:
    import orjson
    _use_orjson = True
except ImportError:
    _use_orjson = False

import json
import os
import pickle
import re
import numpy as np
from typing import Any, Dict, Union, Tuple, Optional
from google.protobuf import any_pb2
from snakepit_bridge.zero_copy import ZeroCopyRef

# Size threshold for using binary serialization (10KB)
BINARY_THRESHOLD = 10_240

# =============================================================================
# Unserializable Marker Constants and Policy
# =============================================================================

# Marker keys - use layer-agnostic naming since this is a transport concern
UNSERIALIZABLE_KEY = "__ffi_unserializable__"
TYPE_KEY = "__type__"
REPR_KEY = "__repr__"

# Policy configuration from environment
_DETAIL_MODE = os.getenv("SNAKEPIT_UNSERIALIZABLE_DETAIL", "none").strip().lower()
_MAXLEN_RAW = int(os.getenv("SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN", "500"))
_MAXLEN = max(0, min(_MAXLEN_RAW, 2000))  # Clamp to 0-2000

# Secret redaction patterns - best-effort mitigation, not a security boundary
_SECRET_PATTERNS = [
    # Authorization headers
    (re.compile(r"(Authorization:\s*Bearer\s+)[^\s'\"\\]+", re.IGNORECASE), r"\1<REDACTED>"),
    # Bearer tokens
    (re.compile(r"(Bearer\s+)[A-Za-z0-9\-\._~\+/]+=*", re.IGNORECASE), r"\1<REDACTED>"),
    # OpenAI-style API keys (sk-...)
    (re.compile(r"\bsk-[A-Za-z0-9]{10,}\b"), "sk-<REDACTED>"),
    # JSON-style sensitive fields
    (re.compile(r'("?(api[_-]?key|token|secret|password)"?\s*[:=]\s*["\'])([^"\']+)(["\'])', re.IGNORECASE), r'\1<REDACTED>\4'),
]


def _redact_secrets(s: str) -> str:
    """
    Best-effort redaction of common secret patterns in text.

    This is a mitigation to reduce accidental leakage, NOT a security boundary.
    It catches common patterns like API keys, bearer tokens, and JSON credentials.
    """
    for pattern, replacement in _SECRET_PATTERNS:
        s = pattern.sub(replacement, s)
    return s


def _unserializable_detail(obj) -> Optional[str]:
    """
    Compute the optional detail string for an unserializable marker.

    Returns None if detail should not be included (default safe mode).
    """
    if _DETAIL_MODE == "none":
        return None

    if _DETAIL_MODE == "type":
        t = f"{type(obj).__module__}.{type(obj).__name__}"
        return f"<unserializable {t}>"

    if _DETAIL_MODE in ("repr_truncated", "repr_redacted_truncated"):
        try:
            s = repr(obj)
        except Exception:
            s = f"<repr failed for {type(obj).__module__}.{type(obj).__name__}>"

        if _DETAIL_MODE == "repr_redacted_truncated":
            s = _redact_secrets(s)

        if _MAXLEN == 0:
            return ""
        return s[:_MAXLEN]

    # Unknown mode => safest behavior (no detail)
    return None


def _unserializable_marker(obj) -> dict:
    """
    Build the marker dict for an unserializable object.

    This is the single source of truth for marker construction.
    Policy determines whether repr is included.
    """
    marker = {
        UNSERIALIZABLE_KEY: True,
        TYPE_KEY: f"{type(obj).__module__}.{type(obj).__name__}",
    }

    detail = _unserializable_detail(obj)
    if detail is not None:
        marker[REPR_KEY] = detail

    return marker


class GracefulJSONEncoder(json.JSONEncoder):
    """
    JSON encoder that gracefully handles non-serializable objects.

    Instead of raising TypeError for non-serializable objects, this encoder:
    1. Tries common conversion methods (model_dump, to_dict, _asdict, tolist, isoformat)
    2. Falls back to a policy-aware marker dict (see module docstring for policy options)

    This allows returning partial data even when some fields contain non-serializable
    objects (like DSPy's ModelResponse, OpenAI's ChatCompletion, etc.).

    By default, markers do NOT include repr (safe for production). Set
    SNAKEPIT_UNSERIALIZABLE_DETAIL to enable repr output.
    """

    def default(self, obj):
        # Try common conversion methods in order of preference
        for method in ('model_dump', 'to_dict', '_asdict', 'tolist'):
            if hasattr(obj, method):
                try:
                    return getattr(obj, method)()
                except Exception:
                    pass

        # datetime/date objects
        if hasattr(obj, 'isoformat'):
            try:
                return obj.isoformat()
            except Exception:
                pass

        # Fallback: create policy-aware unserializable marker
        return _unserializable_marker(obj)


def _orjson_default(obj):
    """
    Default handler for orjson serialization.

    Same logic as GracefulJSONEncoder but as a function for orjson's API.
    Uses the centralized policy-aware marker builder.
    """
    # Try common conversion methods in order of preference
    for method in ('model_dump', 'to_dict', '_asdict', 'tolist'):
        if hasattr(obj, method):
            try:
                return getattr(obj, method)()
            except Exception:
                pass

    # datetime/date objects
    if hasattr(obj, 'isoformat'):
        try:
            return obj.isoformat()
        except Exception:
            pass

    # Fallback: create policy-aware unserializable marker
    return _unserializable_marker(obj)


class TypeSerializer:
    """Unified type serialization for Python side."""
    
    @staticmethod
    def encode_any(value: Any, var_type: str) -> Tuple[any_pb2.Any, Optional[bytes]]:
        """
        Encode a Python value to protobuf Any with optional binary data.
        
        Returns:
            Tuple of (Any message, optional binary data)
        """
        # Normalize value based on type
        normalized = TypeSerializer._normalize_value(value, var_type)
        
        # Check if we should use binary serialization
        if TypeSerializer._should_use_binary(normalized, var_type):
            return TypeSerializer._encode_with_binary(normalized, var_type)
        else:
            # Standard JSON serialization
            json_bytes = TypeSerializer._serialize_value(normalized, var_type)
            
            # Create Any message
            any_msg = any_pb2.Any()
            any_msg.type_url = f"type.googleapis.com/snakepit.{var_type}"
            any_msg.value = json_bytes
            
            return any_msg, None
    
    @staticmethod
    def decode_any(any_msg: any_pb2.Any, binary_data: Optional[bytes] = None) -> Any:
        """
        Decode protobuf Any to Python value with optional binary data.
        
        Args:
            any_msg: Protobuf Any message
            binary_data: Optional binary data for large values
        
        Returns:
            Decoded Python value
        """
        # Check if this is a binary-encoded value
        if any_msg.type_url.endswith('.binary') and binary_data is not None:
            return TypeSerializer._decode_with_binary(any_msg, binary_data)
        else:
            # Standard JSON decoding
            # Extract type from URL - handle various formats:
            # - "type.googleapis.com/snakepit.float" -> "float"
            # - "dspex.variables/float" -> "float"
            # - "type.googleapis.com/google.protobuf.StringValue" -> "StringValue"
            type_url = any_msg.type_url

            # First split by / to get the type part
            if '/' in type_url:
                type_part = type_url.split('/')[-1]  # e.g., "snakepit.float" or "float"
            else:
                type_part = type_url  # No slash, use as-is

            # Then split by . to get the final type
            var_type = type_part.split('.')[-1]  # e.g., "float"

            # Decode JSON
            json_payload = any_msg.value
            value = TypeSerializer._deserialize_json(json_payload)

            # Convert to appropriate Python type
            decoded = TypeSerializer._deserialize_value(value, var_type)
            return TypeSerializer._maybe_zero_copy(decoded)
    
    @staticmethod
    def _normalize_value(value: Any, var_type: str) -> Any:
        """Normalize Python values for consistency."""
        if isinstance(value, ZeroCopyRef):
            return value.to_payload()

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
    def _maybe_zero_copy(value: Any) -> Any:
        if isinstance(value, dict) and value.get("__snakepit_zero_copy__"):
            return ZeroCopyRef.from_payload(value)
        return value
    
    @staticmethod
    def _serialize_value(value: Any, var_type: str) -> bytes:
        """
        Serialize normalized value to JSON bytes.

        Uses orjson for 6x performance boost if available,
        falls back to stdlib json otherwise.
        """
        # Handle special float values
        if var_type == 'float':
            if isinstance(value, float):
                if np.isnan(value):
                    value_to_serialize = "NaN"
                elif np.isinf(value):
                    value_to_serialize = "Infinity" if value > 0 else "-Infinity"
                else:
                    value_to_serialize = value
            else:
                value_to_serialize = value
        else:
            value_to_serialize = value

        # Use orjson if available, otherwise stdlib json
        # Both use graceful fallback for non-serializable objects
        if _use_orjson:
            return orjson.dumps(value_to_serialize, default=_orjson_default)
        else:
            return json.dumps(value_to_serialize, cls=GracefulJSONEncoder).encode('utf-8')
    
    @staticmethod
    def _deserialize_json(json_payload: Union[str, bytes, bytearray]) -> Any:
        """
        Deserialize JSON payload to Python value.

        Uses orjson for 6x performance boost if available,
        falls back to stdlib json otherwise.
        """
        if _use_orjson:
            # orjson.loads accepts str or bytes
            return orjson.loads(json_payload)
        else:
            import json
            return json.loads(json_payload)

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
    
    @staticmethod
    def _should_use_binary(value: Any, var_type: str) -> bool:
        """Check if value should use binary serialization."""
        if var_type not in ['tensor', 'embedding']:
            return False
        
        # Estimate size
        if var_type == 'tensor':
            if isinstance(value, dict) and 'data' in value:
                data = value['data']
                if isinstance(data, list):
                    estimated_size = len(data) * 8  # 8 bytes per float
                    return estimated_size > BINARY_THRESHOLD
        elif var_type == 'embedding':
            if isinstance(value, list):
                estimated_size = len(value) * 8
                return estimated_size > BINARY_THRESHOLD
        
        return False
    
    @staticmethod
    def _encode_with_binary(value: Any, var_type: str) -> Tuple[any_pb2.Any, bytes]:
        """Encode large data with binary serialization."""
        if var_type == 'tensor':
            shape = value.get('shape', [])
            data = value.get('data', [])
            
            # Create metadata
            metadata = {
                'shape': shape,
                'dtype': 'float32',
                'binary_format': 'pickle',
                'type': var_type
            }
            
            # Create Any message with metadata
            any_msg = any_pb2.Any()
            any_msg.type_url = f"type.googleapis.com/snakepit.{var_type}.binary"
            any_msg.value = TypeSerializer._serialize_value(metadata, 'string')
            
            # Serialize data as binary
            binary_data = pickle.dumps(data, protocol=pickle.HIGHEST_PROTOCOL)
            
            return any_msg, binary_data
            
        elif var_type == 'embedding':
            # Create metadata
            metadata = {
                'shape': [len(value)],
                'dtype': 'float32',
                'binary_format': 'pickle',
                'type': var_type
            }
            
            # Create Any message with metadata
            any_msg = any_pb2.Any()
            any_msg.type_url = f"type.googleapis.com/snakepit.{var_type}.binary"
            any_msg.value = TypeSerializer._serialize_value(metadata, 'string')
            
            # Serialize data as binary
            binary_data = pickle.dumps(value, protocol=pickle.HIGHEST_PROTOCOL)
            
            return any_msg, binary_data
        
        else:
            raise ValueError(f"Binary encoding not supported for type: {var_type}")
    
    @staticmethod
    def _decode_with_binary(any_msg: any_pb2.Any, binary_data: bytes) -> Any:
        """Decode binary-encoded data."""
        # Extract base type (remove .binary suffix)
        type_parts = any_msg.type_url.split('.')
        var_type = type_parts[-2]  # Get type before .binary
        
        # Decode metadata
        metadata = TypeSerializer._deserialize_json(any_msg.value)
        
        # Deserialize binary data
        data = pickle.loads(binary_data)
        
        # Reconstruct value based on type
        if var_type == 'tensor':
            return {
                'shape': metadata.get('shape', []),
                'data': data
            }
        elif var_type == 'embedding':
            return data
        else:
            raise ValueError(f"Binary decoding not supported for type: {var_type}")
