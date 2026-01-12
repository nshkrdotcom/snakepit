"""Tests for graceful serialization fallback."""

import pytest
import json
import os
from datetime import datetime, date
from decimal import Decimal
from unittest.mock import patch

from snakepit_bridge.serialization import (
    TypeSerializer,
    GracefulJSONEncoder,
    _orjson_default,
    UNSERIALIZABLE_KEY,
    TYPE_KEY,
    REPR_KEY,
)


class CustomObject:
    """Non-serializable test object."""
    def __init__(self, value):
        self.value = value

    def __repr__(self):
        return f"CustomObject({self.value!r})"


class PydanticLike:
    """Object with model_dump method (like Pydantic v2)."""
    def __init__(self, data):
        self.data = data

    def model_dump(self):
        return {"data": self.data}


class DictConvertible:
    """Object with to_dict method."""
    def __init__(self, x):
        self.x = x

    def to_dict(self):
        return {"x": self.x}


class NamedTupleLike:
    """Object with _asdict method (like namedtuple)."""
    def __init__(self, a, b):
        self.a = a
        self.b = b

    def _asdict(self):
        return {"a": self.a, "b": self.b}


class ListConvertible:
    """Object with tolist method (like numpy arrays)."""
    def __init__(self, items):
        self.items = items

    def tolist(self):
        return list(self.items)


class TestGracefulJSONEncoder:
    """Test stdlib json encoder with graceful fallback."""

    def test_basic_types_unchanged(self):
        """Basic JSON types serialize normally."""
        data = {"string": "hello", "number": 42, "list": [1, 2, 3], "null": None, "bool": True}
        result = json.dumps(data, cls=GracefulJSONEncoder)
        assert json.loads(result) == data

    def test_datetime_uses_isoformat(self):
        """Datetime objects converted via isoformat."""
        dt = datetime(2026, 1, 11, 10, 30, 0)
        result = json.dumps({"time": dt}, cls=GracefulJSONEncoder)
        assert json.loads(result)["time"] == "2026-01-11T10:30:00"

    def test_date_uses_isoformat(self):
        """Date objects converted via isoformat."""
        d = date(2026, 1, 11)
        result = json.dumps({"date": d}, cls=GracefulJSONEncoder)
        assert json.loads(result)["date"] == "2026-01-11"

    def test_model_dump_method_used(self):
        """Objects with model_dump() are converted (Pydantic v2 style)."""
        obj = PydanticLike("test")
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == {"data": "test"}

    def test_to_dict_method_used(self):
        """Objects with to_dict() are converted."""
        obj = DictConvertible(42)
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == {"x": 42}

    def test_asdict_method_used(self):
        """Objects with _asdict() are converted (namedtuple style)."""
        obj = NamedTupleLike(1, 2)
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == {"a": 1, "b": 2}

    def test_tolist_method_used(self):
        """Objects with tolist() are converted (numpy style)."""
        obj = ListConvertible([1, 2, 3])
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        assert json.loads(result)["obj"] == [1, 2, 3]

    def test_fallback_creates_marker(self):
        """Non-convertible objects get unserializable marker."""
        obj = CustomObject("test")
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)["obj"]

        assert parsed[UNSERIALIZABLE_KEY] is True
        assert "CustomObject" in parsed[TYPE_KEY]
        # Note: By default, repr is NOT included (safe mode)
        # Use SNAKEPIT_UNSERIALIZABLE_DETAIL=repr_truncated to include repr

    def test_nested_unserializable_in_list(self):
        """Nested unserializable objects in lists are handled."""
        data = {"items": [1, CustomObject("a"), 3]}
        result = json.dumps(data, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        assert parsed["items"][0] == 1
        assert parsed["items"][1][UNSERIALIZABLE_KEY] is True
        assert parsed["items"][2] == 3

    def test_nested_unserializable_in_dict(self):
        """Nested unserializable objects in dicts are handled."""
        data = {"good": 123, "bad": CustomObject("x")}
        result = json.dumps(data, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        assert parsed["good"] == 123
        assert parsed["bad"][UNSERIALIZABLE_KEY] is True

    def test_deeply_nested(self):
        """Deeply nested structures with unserializable objects work."""
        data = {
            "level1": {
                "level2": [
                    {"level3": CustomObject("deep")}
                ]
            }
        }
        result = json.dumps(data, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        assert parsed["level1"]["level2"][0]["level3"][UNSERIALIZABLE_KEY] is True

    def test_long_repr_truncated_when_enabled(self):
        """Very long repr strings are truncated when repr mode is enabled."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_truncated"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class LongRepr:
                def __repr__(self):
                    return "x" * 1000

            obj = LongRepr()
            result = json.dumps({"obj": obj}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)["obj"]

            assert len(parsed[REPR_KEY]) <= 500

    def test_conversion_method_exception_falls_through(self):
        """If a conversion method raises, try next method or fallback."""
        class BadModelDump:
            def model_dump(self):
                raise ValueError("broken")
            def to_dict(self):
                return {"fallback": True}

        obj = BadModelDump()
        result = json.dumps({"obj": obj}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)["obj"]

        # Should have used to_dict() after model_dump() failed
        assert parsed == {"fallback": True}


class TestOrjsonDefault:
    """Test orjson default handler."""

    def test_datetime_converted(self):
        """Datetime converted via isoformat."""
        dt = datetime(2026, 1, 11, 10, 30, 0)
        result = _orjson_default(dt)
        assert result == "2026-01-11T10:30:00"

    def test_model_dump_used(self):
        """Objects with model_dump() are converted."""
        obj = PydanticLike("test")
        result = _orjson_default(obj)
        assert result == {"data": "test"}

    def test_to_dict_used(self):
        """Objects with to_dict() are converted."""
        obj = DictConvertible(42)
        result = _orjson_default(obj)
        assert result == {"x": 42}

    def test_fallback_marker(self):
        """Non-convertible objects get marker."""
        obj = CustomObject("test")
        result = _orjson_default(obj)

        assert result[UNSERIALIZABLE_KEY] is True
        assert "CustomObject" in result[TYPE_KEY]
        # Note: By default, repr is NOT included (safe mode)


class TestTypeSerializerIntegration:
    """Integration tests with TypeSerializer."""

    def test_list_with_unserializable_succeeds(self):
        """TypeSerializer handles lists containing unserializable items."""
        data = [1, "two", CustomObject("three")]
        # Should NOT raise - graceful fallback
        any_msg, binary_data = TypeSerializer.encode_any(data, "list")
        assert any_msg is not None

    def test_dict_with_unserializable_succeeds(self):
        """TypeSerializer handles dicts with unserializable values."""
        data = {"good": 123, "bad": CustomObject("value")}
        # Should NOT raise - graceful fallback
        any_msg, binary_data = TypeSerializer.encode_any(data, "map")
        assert any_msg is not None

    def test_string_type_unchanged(self):
        """String type still works normally."""
        any_msg, binary_data = TypeSerializer.encode_any("hello", "string")
        assert any_msg is not None

    def test_float_type_unchanged(self):
        """Float type still works normally."""
        any_msg, binary_data = TypeSerializer.encode_any(3.14, "float")
        assert any_msg is not None


class TestRealWorldScenarios:
    """Tests mimicking real library scenarios."""

    def test_dspy_history_like_structure(self):
        """Simulate DSPy GLOBAL_HISTORY structure."""

        class FakeModelResponse:
            def __init__(self, id):
                self.id = id
            def __repr__(self):
                return f"ModelResponse(id={self.id!r})"

        history = [
            {
                "model": "gemini/gemini-flash-lite",
                "cost": 0.0001,
                "timestamp": "2026-01-11T10:30:00",
                "messages": [{"role": "user", "content": "Hello"}],
                "outputs": ["Hi there!"],
                "response": FakeModelResponse("chat-123")
            }
        ]

        result = json.dumps(history, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        # All serializable fields preserved
        assert parsed[0]["model"] == "gemini/gemini-flash-lite"
        assert parsed[0]["cost"] == 0.0001
        assert parsed[0]["messages"] == [{"role": "user", "content": "Hello"}]
        assert parsed[0]["outputs"] == ["Hi there!"]

        # Non-serializable field replaced with marker
        assert parsed[0]["response"][UNSERIALIZABLE_KEY] is True
        assert "ModelResponse" in parsed[0]["response"][TYPE_KEY]
        # Note: By default, repr is NOT included (safe mode)

    def test_openai_like_response(self):
        """Simulate OpenAI ChatCompletion-like object with model_dump."""

        class FakeChatCompletion:
            def __init__(self):
                self.id = "chatcmpl-123"
                self.model = "gpt-4"

            def model_dump(self):
                return {"id": self.id, "model": self.model}

        response = FakeChatCompletion()
        result = json.dumps({"response": response}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        # Should use model_dump()
        assert parsed["response"] == {"id": "chatcmpl-123", "model": "gpt-4"}

    def test_requests_response_like(self):
        """Simulate requests.Response-like object (no conversion methods)."""

        class FakeResponse:
            def __init__(self):
                self.status_code = 200
                self.url = "https://example.com"

            def __repr__(self):
                return f"<Response [{self.status_code}]>"

        response = FakeResponse()
        result = json.dumps({"response": response}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        # Should fall back to marker
        assert parsed["response"][UNSERIALIZABLE_KEY] is True
        assert "FakeResponse" in parsed["response"][TYPE_KEY]
        # Note: By default, repr is NOT included (safe mode)
        # Use SNAKEPIT_UNSERIALIZABLE_DETAIL=repr_truncated to include repr
