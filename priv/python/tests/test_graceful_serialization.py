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


class TestTolistSizeGuard:
    """Test size guard for tolist() conversion."""

    def test_small_tolist_converted(self):
        """Small tolist() results are converted normally."""
        class SmallArray:
            def tolist(self):
                return [1, 2, 3, 4, 5]

        obj = SmallArray()
        result = json.dumps({"arr": obj}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        assert parsed["arr"] == [1, 2, 3, 4, 5]

    def test_huge_tolist_falls_back_to_marker(self):
        """tolist() results exceeding threshold fall back to marker.

        Note: We use a lowered threshold instead of actually allocating huge data
        to avoid CI memory issues and slow tests.
        """
        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class OverThresholdArray:
                """Array that would exceed the lowered threshold."""
                def tolist(self):
                    return list(range(150))  # 150 > 100 threshold

                def __repr__(self):
                    return "<OverThresholdArray size=150>"

            obj = OverThresholdArray()
            result = json.dumps({"arr": obj}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should have fallen back to marker instead of large list
            assert parsed["arr"][serialization.UNSERIALIZABLE_KEY] is True
            assert "OverThresholdArray" in parsed["arr"][serialization.TYPE_KEY]

    def test_tolist_size_threshold_configurable(self):
        """Tolist size threshold can be configured via env var."""
        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class MediumArray:
                def tolist(self):
                    return list(range(200))  # 200 elements > 100 threshold

            obj = MediumArray()
            result = json.dumps({"arr": obj}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should fall back to marker because 200 > 100
            assert parsed["arr"][serialization.UNSERIALIZABLE_KEY] is True

    def test_tolist_at_threshold_converted(self):
        """tolist() at exactly the threshold is converted."""
        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class ExactArray:
                def tolist(self):
                    return list(range(100))  # Exactly 100 elements

            obj = ExactArray()
            result = json.dumps({"arr": obj}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should be converted (at threshold, not over)
            assert parsed["arr"] == list(range(100))

    def test_tolist_exception_falls_through(self):
        """If tolist() raises, fallback to marker."""
        class BrokenArray:
            def tolist(self):
                raise RuntimeError("Cannot convert")

        obj = BrokenArray()
        result = json.dumps({"arr": obj}, cls=GracefulJSONEncoder)
        parsed = json.loads(result)

        # Should fall back to marker
        assert parsed["arr"][UNSERIALIZABLE_KEY] is True

    def test_numpy_pre_check_blocks_huge_array(self):
        """Pre-check blocks numpy arrays before tolist() allocation using isinstance."""
        import numpy as np

        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            # Create actual numpy array that exceeds threshold
            arr = np.zeros(200)  # 200 > 100 threshold

            result = json.dumps({"arr": arr}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should fall back to marker (numpy array detected via isinstance)
            assert parsed["arr"][serialization.UNSERIALIZABLE_KEY] is True
            assert "ndarray" in parsed["arr"][serialization.TYPE_KEY]

    def test_numpy_pre_check_prevents_tolist_call(self):
        """Pre-check prevents tolist() from being called for oversized numpy arrays.

        This is the critical invariant: we avoid the allocation work entirely.
        Uses a numpy subclass to track tolist() calls since np.ndarray can't be monkeypatched.
        """
        import numpy as np

        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            # Create a numpy subclass that tracks tolist() calls
            class TrackedArray(np.ndarray):
                tolist_called = False

                def tolist(self):
                    TrackedArray.tolist_called = True
                    return super().tolist()

            # Create array via view to get our subclass
            TrackedArray.tolist_called = False
            arr = np.zeros(200).view(TrackedArray)  # 200 > 100 threshold

            # Verify it's detected as numpy via isinstance
            assert isinstance(arr, np.ndarray)

            result = json.dumps({"arr": arr}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should fall back to marker
            assert parsed["arr"][serialization.UNSERIALIZABLE_KEY] is True

            # Critical: tolist() should NOT have been called
            assert not TrackedArray.tolist_called, "tolist() was called but should have been blocked by pre-check"

    def test_numpy_pre_check_allows_small_array(self):
        """Pre-check allows numpy arrays within threshold."""
        import numpy as np

        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            # Create actual numpy array within threshold
            arr = np.array([1, 2, 3, 4, 5])  # 5 < 100 threshold

            result = json.dumps({"arr": arr}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should convert normally via tolist()
            assert parsed["arr"] == [1, 2, 3, 4, 5]

    def test_sparse_like_pre_check_uses_int_cast(self):
        """Pre-check for sparse matrices uses int() cast to prevent overflow."""
        with patch.dict(os.environ, {"SNAKEPIT_TOLIST_MAX_ELEMENTS": "100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class SparseLikeMatrix:
                """Mimics scipy sparse matrix with nnz and shape."""
                def __init__(self, shape):
                    self.nnz = 5  # Few non-zeros
                    self.shape = shape  # But large dense shape

                def tolist(self):
                    # Would return huge list if called
                    raise RuntimeError("Should not be called!")

            # Shape product = 20 * 20 = 400 > 100 threshold
            obj = SparseLikeMatrix((20, 20))
            result = json.dumps({"arr": obj}, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should fall back to marker WITHOUT calling tolist()
            assert parsed["arr"][serialization.UNSERIALIZABLE_KEY] is True
