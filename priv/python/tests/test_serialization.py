"""
Tests for the serialization module.
"""

import unittest
import json
import numpy as np
from snakepit_bridge.serialization import TypeSerializer
from google.protobuf import any_pb2


class TestBasicTypes(unittest.TestCase):
    """Test serialization of basic types."""
    
    def test_float_roundtrip(self):
        value = 3.14
        any_msg = TypeSerializer.encode_any(value, 'float')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_integer_roundtrip(self):
        value = 42
        any_msg = TypeSerializer.encode_any(value, 'integer')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_string_roundtrip(self):
        value = "hello world"
        any_msg = TypeSerializer.encode_any(value, 'string')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_boolean_roundtrip(self):
        for value in [True, False]:
            any_msg = TypeSerializer.encode_any(value, 'boolean')
            decoded = TypeSerializer.decode_any(any_msg)
            self.assertEqual(decoded, value)


class TestSpecialFloatValues(unittest.TestCase):
    """Test special float values."""
    
    def test_nan(self):
        value = float('nan')
        any_msg = TypeSerializer.encode_any(value, 'float')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertTrue(np.isnan(decoded))
    
    def test_infinity(self):
        value = float('inf')
        any_msg = TypeSerializer.encode_any(value, 'float')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, float('inf'))
    
    def test_negative_infinity(self):
        value = float('-inf')
        any_msg = TypeSerializer.encode_any(value, 'float')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, float('-inf'))


class TestComplexTypes(unittest.TestCase):
    """Test serialization of complex types."""
    
    def test_choice_roundtrip(self):
        value = "option_a"
        any_msg = TypeSerializer.encode_any(value, 'choice')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_module_roundtrip(self):
        value = "ChainOfThought"
        any_msg = TypeSerializer.encode_any(value, 'module')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_embedding_roundtrip(self):
        value = [0.1, 0.2, 0.3, 0.4]
        any_msg = TypeSerializer.encode_any(value, 'embedding')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value)
    
    def test_embedding_numpy_array(self):
        value = np.array([0.1, 0.2, 0.3, 0.4])
        any_msg = TypeSerializer.encode_any(value, 'embedding')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, value.tolist())
    
    def test_tensor_dict_roundtrip(self):
        value = {'shape': [2, 3], 'data': [1, 2, 3, 4, 5, 6]}
        any_msg = TypeSerializer.encode_any(value, 'tensor')
        decoded = TypeSerializer.decode_any(any_msg)
        np.testing.assert_array_equal(decoded, np.array([1, 2, 3, 4, 5, 6]).reshape(2, 3))
    
    def test_tensor_numpy_array(self):
        value = np.array([[1, 2, 3], [4, 5, 6]])
        any_msg = TypeSerializer.encode_any(value, 'tensor')
        decoded = TypeSerializer.decode_any(any_msg)
        np.testing.assert_array_equal(decoded, value)


class TestConstraintValidation(unittest.TestCase):
    """Test constraint validation."""
    
    def test_numeric_constraints(self):
        constraints = {'min': 0, 'max': 1}
        
        # Valid values
        TypeSerializer.validate_constraints(0.5, 'float', constraints)
        
        # Invalid values
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints(1.5, 'float', constraints)
        
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints(-0.5, 'float', constraints)
    
    def test_string_constraints(self):
        constraints = {'min_length': 3, 'max_length': 10}
        
        # Valid
        TypeSerializer.validate_constraints("hello", 'string', constraints)
        
        # Too short
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints("hi", 'string', constraints)
        
        # Too long
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints("this is too long", 'string', constraints)
    
    def test_choice_constraints(self):
        constraints = {'choices': ['a', 'b', 'c']}
        
        # Valid
        TypeSerializer.validate_constraints('a', 'choice', constraints)
        
        # Invalid
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints('d', 'choice', constraints)
    
    def test_embedding_dimension_constraints(self):
        constraints = {'dimensions': 4}
        
        # Valid
        TypeSerializer.validate_constraints([1, 2, 3, 4], 'embedding', constraints)
        
        # Wrong dimension
        with self.assertRaises(ValueError):
            TypeSerializer.validate_constraints([1, 2, 3], 'embedding', constraints)


class TestTypeValidation(unittest.TestCase):
    """Test type validation and normalization."""
    
    def test_float_accepts_integers(self):
        any_msg = TypeSerializer.encode_any(42, 'float')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, 42.0)
    
    def test_integer_rejects_floats_with_decimals(self):
        with self.assertRaises(ValueError):
            TypeSerializer.encode_any(3.14, 'integer')
    
    def test_integer_accepts_whole_floats(self):
        any_msg = TypeSerializer.encode_any(42.0, 'integer')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, 42)
    
    def test_embedding_normalizes_to_floats(self):
        any_msg = TypeSerializer.encode_any([1, 2, 3], 'embedding')
        decoded = TypeSerializer.decode_any(any_msg)
        self.assertEqual(decoded, [1.0, 2.0, 3.0])


class TestCrossLanguageCompatibility(unittest.TestCase):
    """Test compatibility with Elixir serialization."""
    
    def test_elixir_float_format(self):
        # Test that we can decode Elixir-encoded floats
        elixir_any = any_pb2.Any()
        elixir_any.type_url = "dspex.variables/float"
        elixir_any.value = b"3.14"
        
        decoded = TypeSerializer.decode_any(elixir_any)
        self.assertEqual(decoded, 3.14)
    
    def test_elixir_special_float_values(self):
        # Test special values
        for elixir_value, expected in [("\"NaN\"", float('nan')), 
                                       ("\"Infinity\"", float('inf')),
                                       ("\"-Infinity\"", float('-inf'))]:
            elixir_any = any_pb2.Any()
            elixir_any.type_url = "dspex.variables/float"
            elixir_any.value = elixir_value.encode('utf-8')
            
            decoded = TypeSerializer.decode_any(elixir_any)
            if elixir_value == "\"NaN\"":
                self.assertTrue(np.isnan(decoded))
            else:
                self.assertEqual(decoded, expected)


if __name__ == '__main__':
    unittest.main()