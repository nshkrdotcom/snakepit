"""Tests for serialization policy behavior.

These tests verify that:
1. Default mode does NOT include repr (safe by default)
2. repr is not even evaluated when mode is 'none'
3. Opt-in modes work correctly
4. Redaction works for common secret patterns
"""

import pytest
import json
import os
from unittest.mock import patch

# Import will happen after we implement the module
# For now, we define what we expect to import
from snakepit_bridge.serialization import (
    GracefulJSONEncoder,
    _orjson_default,
    _unserializable_marker,
    _unserializable_detail,
    _redact_secrets,
    UNSERIALIZABLE_KEY,
    TYPE_KEY,
    REPR_KEY,
)


class ReprCounter:
    """Object that counts how many times __repr__ is called."""
    call_count = 0

    def __repr__(self):
        ReprCounter.call_count += 1
        return "ReprCounter()"


class ReprRaises:
    """Object whose __repr__ raises an exception."""
    def __repr__(self):
        raise RuntimeError("repr should not be called!")


class SecretHolder:
    """Object with secrets in its repr."""
    def __repr__(self):
        return (
            "SecretHolder(api_key='sk-abc123xyz789', "
            "token='Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9', "
            "auth='Authorization: Bearer secret123')"
        )


class TestDefaultPolicyNoRepr:
    """Test that default policy does NOT include repr."""

    def test_default_marker_has_no_repr_key(self):
        """Default mode: marker should NOT contain __repr__ key."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "none"}):
            # Re-import to pick up env var
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                pass

            marker = serialization._unserializable_marker(CustomObject())

            assert marker[serialization.UNSERIALIZABLE_KEY] is True
            assert serialization.TYPE_KEY in marker
            assert serialization.REPR_KEY not in marker

    def test_default_marker_without_env_var(self):
        """When env var is unset, default to 'none' (no repr)."""
        with patch.dict(os.environ, {}, clear=True):
            # Remove the env var if present
            os.environ.pop("SNAKEPIT_UNSERIALIZABLE_DETAIL", None)

            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                pass

            marker = serialization._unserializable_marker(CustomObject())
            assert serialization.REPR_KEY not in marker

    def test_repr_not_evaluated_in_default_mode(self):
        """Critical: repr() should NOT be called when mode is 'none'."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "none"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            ReprCounter.call_count = 0
            obj = ReprCounter()

            # Build marker
            marker = serialization._unserializable_marker(obj)

            # repr should NOT have been called
            assert ReprCounter.call_count == 0, "repr() was called but should not be in default mode"

    def test_repr_raising_does_not_affect_default_mode(self):
        """Object with raising __repr__ should not cause issues in default mode."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "none"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            obj = ReprRaises()

            # Should NOT raise - repr is not called in default mode
            marker = serialization._unserializable_marker(obj)
            assert marker[serialization.UNSERIALIZABLE_KEY] is True


class TestReprTruncatedMode:
    """Test repr_truncated mode."""

    def test_repr_included_when_enabled(self):
        """repr_truncated mode: marker should contain __repr__ key."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_truncated"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                def __repr__(self):
                    return "CustomObject(value=42)"

            marker = serialization._unserializable_marker(CustomObject())

            assert serialization.REPR_KEY in marker
            assert marker[serialization.REPR_KEY] == "CustomObject(value=42)"

    def test_repr_truncated_to_maxlen(self):
        """repr should be truncated to SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN."""
        with patch.dict(os.environ, {
            "SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_truncated",
            "SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": "20"
        }):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class LongRepr:
                def __repr__(self):
                    return "x" * 100

            marker = serialization._unserializable_marker(LongRepr())

            assert len(marker[serialization.REPR_KEY]) == 20

    def test_maxlen_clamped_to_upper_bound(self):
        """MAXLEN should be clamped to 2000 even if env var is larger."""
        with patch.dict(os.environ, {
            "SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_truncated",
            "SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": "99999"
        }):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class HugeRepr:
                def __repr__(self):
                    return "x" * 10000

            marker = serialization._unserializable_marker(HugeRepr())

            # Should be clamped to 2000
            assert len(marker[serialization.REPR_KEY]) <= 2000

    def test_repr_exception_handled_gracefully(self):
        """If repr() raises, should return a fallback string."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_truncated"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            marker = serialization._unserializable_marker(ReprRaises())

            assert serialization.REPR_KEY in marker
            assert "<repr failed" in marker[serialization.REPR_KEY]


class TestReprRedactedMode:
    """Test repr_redacted_truncated mode."""

    def test_secrets_redacted(self):
        """Known secret patterns should be redacted."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "repr_redacted_truncated"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            marker = serialization._unserializable_marker(SecretHolder())
            repr_val = marker[serialization.REPR_KEY]

            # Original secrets should NOT be present
            assert "sk-abc123xyz789" not in repr_val
            assert "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" not in repr_val
            assert "secret123" not in repr_val

            # Redaction markers should be present
            assert "<REDACTED>" in repr_val


class TestRedactSecrets:
    """Test the _redact_secrets function directly."""

    def test_openai_style_api_key(self):
        """OpenAI sk-... keys should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = "api_key=sk-abcdefghijklmnop"
        result = _redact_secrets(text)
        assert "sk-abcdefghijklmnop" not in result
        assert "sk-<REDACTED>" in result

    def test_bearer_token(self):
        """Bearer tokens should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.abc"
        result = _redact_secrets(text)
        assert "eyJhbGciOiJIUzI1NiJ9" not in result
        assert "<REDACTED>" in result

    def test_json_style_api_key(self):
        """JSON-style api_key fields should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = '{"api_key": "my-secret-key-12345"}'
        result = _redact_secrets(text)
        assert "my-secret-key-12345" not in result
        assert "<REDACTED>" in result

    def test_json_style_token(self):
        """JSON-style token fields should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = '{"token": "abc123secret"}'
        result = _redact_secrets(text)
        assert "abc123secret" not in result

    def test_json_style_secret(self):
        """JSON-style secret fields should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = '{"secret": "supersecret"}'
        result = _redact_secrets(text)
        assert "supersecret" not in result

    def test_json_style_password(self):
        """JSON-style password fields should be redacted."""
        from snakepit_bridge.serialization import _redact_secrets

        text = '{"password": "hunter2"}'
        result = _redact_secrets(text)
        assert "hunter2" not in result

    def test_preserves_non_secret_content(self):
        """Non-secret content should be preserved."""
        from snakepit_bridge.serialization import _redact_secrets

        text = "User(name='Alice', age=30)"
        result = _redact_secrets(text)
        assert result == text


class TestTypeModeDetail:
    """Test the 'type' detail mode."""

    def test_type_mode_produces_placeholder(self):
        """type mode should produce a placeholder string, not call repr."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "type"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            ReprCounter.call_count = 0
            obj = ReprCounter()

            marker = serialization._unserializable_marker(obj)

            # repr should NOT be called
            assert ReprCounter.call_count == 0

            # Should have a placeholder in __repr__
            assert serialization.REPR_KEY in marker
            assert "<unserializable" in marker[serialization.REPR_KEY]
            assert "ReprCounter" in marker[serialization.REPR_KEY]


class TestMarkerIntegration:
    """Test marker works correctly through JSON encoding."""

    def test_json_encoding_uses_marker_policy(self):
        """GracefulJSONEncoder should use the policy-aware marker."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "none"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                def __repr__(self):
                    return "CustomObject(secret=sk-12345)"

            data = {"obj": CustomObject()}
            result = json.dumps(data, cls=serialization.GracefulJSONEncoder)
            parsed = json.loads(result)

            # Should NOT contain repr (or secrets)
            assert serialization.REPR_KEY not in parsed["obj"]
            assert "sk-12345" not in result

    def test_orjson_default_uses_marker_policy(self):
        """_orjson_default should use the policy-aware marker."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "none"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                def __repr__(self):
                    return "CustomObject(secret=sk-12345)"

            result = serialization._orjson_default(CustomObject())

            assert serialization.REPR_KEY not in result


class TestUnknownModeDefaultsToSafe:
    """Test that unknown modes default to safe behavior."""

    def test_unknown_mode_no_repr(self):
        """Unknown mode should default to no repr (safest)."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_DETAIL": "invalid_mode"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)

            class CustomObject:
                pass

            marker = serialization._unserializable_marker(CustomObject())
            assert serialization.REPR_KEY not in marker


class TestEnvVarParsingRobustness:
    """Test that bad env var values don't crash the module."""

    def test_invalid_maxlen_defaults_gracefully(self):
        """Non-integer MAXLEN should not crash module import."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": "not_a_number"}):
            from snakepit_bridge import serialization
            import importlib
            # This should NOT raise - must handle gracefully
            importlib.reload(serialization)
            # Should fall back to default
            assert serialization._MAXLEN == 500

    def test_empty_maxlen_defaults_gracefully(self):
        """Empty MAXLEN should not crash module import."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": ""}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)
            assert serialization._MAXLEN == 500

    def test_whitespace_maxlen_handled(self):
        """MAXLEN with whitespace should be handled."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": "  200  "}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)
            assert serialization._MAXLEN == 200

    def test_negative_maxlen_clamped(self):
        """Negative MAXLEN should be clamped to 0."""
        with patch.dict(os.environ, {"SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN": "-100"}):
            from snakepit_bridge import serialization
            import importlib
            importlib.reload(serialization)
            assert serialization._MAXLEN == 0


class TestMarkerTelemetry:
    """Test telemetry emission for marker creation."""

    def test_telemetry_emitted_on_marker_creation(self):
        """Marker creation should emit telemetry event."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set for clean test
        serialization._emitted_marker_types.clear()

        # Track emitted events
        emitted_events = []

        class MockBackend:
            def emit(self, event, measurements, metadata, correlation_id):
                emitted_events.append({
                    "event": event,
                    "measurements": measurements,
                    "metadata": metadata,
                })

        # Install mock backend
        original_backend = telemetry.get_backend()
        telemetry.set_backend(MockBackend())

        try:
            class CustomObject:
                pass

            serialization._unserializable_marker(CustomObject())

            # Should have emitted one event
            assert len(emitted_events) == 1
            assert emitted_events[0]["event"] == "snakepit.serialization.unserializable_marker"
            assert emitted_events[0]["measurements"]["first_seen"] == 1
            assert "CustomObject" in emitted_events[0]["metadata"]["type"]
        finally:
            telemetry.set_backend(original_backend)

    def test_telemetry_includes_type_not_repr(self):
        """Telemetry should include type info but never repr."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set for clean test
        serialization._emitted_marker_types.clear()

        emitted_events = []

        class MockBackend:
            def emit(self, event, measurements, metadata, correlation_id):
                emitted_events.append(metadata)

        original_backend = telemetry.get_backend()
        telemetry.set_backend(MockBackend())

        try:
            class SecretObject:
                def __repr__(self):
                    return "SecretObject(api_key='sk-supersecret123')"

            serialization._unserializable_marker(SecretObject())

            # Metadata should have type but NOT repr
            assert len(emitted_events) == 1
            assert "type" in emitted_events[0]
            assert "repr" not in emitted_events[0]
            # Verify no secrets leaked
            assert "sk-supersecret" not in str(emitted_events[0])
        finally:
            telemetry.set_backend(original_backend)

    def test_telemetry_disabled_no_error(self):
        """When telemetry backend is None, marker creation should not fail."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set for clean test
        serialization._emitted_marker_types.clear()

        # Ensure no backend
        original_backend = telemetry.get_backend()
        telemetry.set_backend(None)

        try:
            class CustomObject:
                pass

            # Should not raise
            marker = serialization._unserializable_marker(CustomObject())
            assert marker[serialization.UNSERIALIZABLE_KEY] is True
        finally:
            telemetry.set_backend(original_backend)

    def test_telemetry_deduplicated_per_type(self):
        """Telemetry is deduplicated per type to avoid high cardinality."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set for clean test
        serialization._emitted_marker_types.clear()

        emitted_events = []

        class MockBackend:
            def emit(self, event, measurements, metadata, correlation_id):
                emitted_events.append(metadata)

        original_backend = telemetry.get_backend()
        telemetry.set_backend(MockBackend())

        try:
            class RepeatedObject:
                pass

            # Create multiple markers for same type
            serialization._unserializable_marker(RepeatedObject())
            serialization._unserializable_marker(RepeatedObject())
            serialization._unserializable_marker(RepeatedObject())

            # Should only emit ONCE despite multiple markers
            assert len(emitted_events) == 1
            assert "RepeatedObject" in emitted_events[0]["type"]
        finally:
            telemetry.set_backend(original_backend)

    def test_telemetry_error_does_not_break_serialization(self):
        """Telemetry errors should never break marker creation."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set for clean test
        serialization._emitted_marker_types.clear()

        class BrokenBackend:
            def emit(self, event, measurements, metadata, correlation_id):
                raise RuntimeError("Telemetry backend is broken!")

        original_backend = telemetry.get_backend()
        telemetry.set_backend(BrokenBackend())

        try:
            class CustomObject:
                pass

            # Should NOT raise despite broken telemetry
            marker = serialization._unserializable_marker(CustomObject())
            assert marker[serialization.UNSERIALIZABLE_KEY] is True
        finally:
            telemetry.set_backend(original_backend)

    def test_telemetry_dedup_set_capped(self):
        """Deduplication set is capped to prevent unbounded memory AND telemetry cardinality."""
        from snakepit_bridge import serialization
        from snakepit_bridge import telemetry

        # Clear deduplication set
        serialization._emitted_marker_types.clear()

        emitted_events = []

        class MockBackend:
            def emit(self, event, measurements, metadata, correlation_id):
                emitted_events.append(metadata)

        original_backend = telemetry.get_backend()
        telemetry.set_backend(MockBackend())

        # Save original cap and set a small one for testing
        original_cap = serialization._EMITTED_MARKER_TYPES_MAX
        serialization._EMITTED_MARKER_TYPES_MAX = 3

        try:
            # Create 5 different types, but cap is 3
            for i in range(5):
                # Create a unique class each time
                cls = type(f"DynamicClass{i}", (), {})
                serialization._unserializable_marker(cls())

            # Should have emitted only 3 events (cap applies to both set AND telemetry)
            assert len(emitted_events) == 3

            # Set should also be capped at 3
            assert len(serialization._emitted_marker_types) == 3

            # Verify the first 3 types were recorded
            recorded_types = {t for t in serialization._emitted_marker_types}
            assert any("DynamicClass0" in t for t in recorded_types)
            assert any("DynamicClass1" in t for t in recorded_types)
            assert any("DynamicClass2" in t for t in recorded_types)
        finally:
            telemetry.set_backend(original_backend)
            serialization._EMITTED_MARKER_TYPES_MAX = original_cap
