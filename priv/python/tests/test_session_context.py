"""
Tests for the minimal SessionContext.
"""

import unittest
from unittest.mock import Mock, MagicMock, patch
from google.protobuf.struct_pb2 import Struct
from google.protobuf.any_pb2 import Any as ProtoAny

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from snakepit_bridge.session_context import SessionContext
from snakepit_bridge_pb2 import (
    CleanupSessionRequest,
    CleanupSessionResponse,
    GetExposedElixirToolsRequest,
    GetExposedElixirToolsResponse,
    ExecuteElixirToolRequest,
    ExecuteElixirToolResponse,
    ToolSpec
)


class TestSessionContextInit(unittest.TestCase):
    """Test SessionContext initialization."""

    def test_init_with_stub_and_session_id(self):
        """Test basic initialization."""
        stub = Mock()
        session_id = "test_session_123"

        ctx = SessionContext(stub, session_id)

        self.assertEqual(ctx.stub, stub)
        self.assertEqual(ctx.session_id, session_id)
        self.assertIsNone(ctx._elixir_tools)

    def test_repr(self):
        """Test string representation."""
        stub = Mock()
        session_id = "test_session_456"

        ctx = SessionContext(stub, session_id)

        self.assertEqual(repr(ctx), "SessionContext(session_id='test_session_456')")


class TestElixirToolsProperty(unittest.TestCase):
    """Test elixir_tools lazy loading."""

    def test_elixir_tools_lazy_load(self):
        """Test that elixir_tools are loaded on first access."""
        stub = Mock()
        session_id = "test_session"

        # Mock the RPC response
        tool_spec = ToolSpec(
            name="test_tool",
            description="A test tool",
            parameters={"arg1": "string"}
        )
        response = GetExposedElixirToolsResponse()
        response.tools["test_tool"].CopyFrom(tool_spec)

        stub.GetExposedElixirTools.return_value = response

        ctx = SessionContext(stub, session_id)

        # Tools should not be loaded yet
        self.assertIsNone(ctx._elixir_tools)

        # Access property - should trigger load
        tools = ctx.elixir_tools

        # Verify RPC was called
        stub.GetExposedElixirTools.assert_called_once()
        call_args = stub.GetExposedElixirTools.call_args[0][0]
        self.assertEqual(call_args.session_id, session_id)

        # Verify tools were loaded
        self.assertIsNotNone(ctx._elixir_tools)
        self.assertIn("test_tool", tools)
        self.assertEqual(tools["test_tool"]["name"], "test_tool")
        self.assertEqual(tools["test_tool"]["description"], "A test tool")

    def test_elixir_tools_cached_after_first_load(self):
        """Test that tools are only loaded once."""
        stub = Mock()
        response = GetExposedElixirToolsResponse()
        stub.GetExposedElixirTools.return_value = response

        ctx = SessionContext(stub, "test_session")

        # Access twice
        tools1 = ctx.elixir_tools
        tools2 = ctx.elixir_tools

        # RPC should only be called once
        stub.GetExposedElixirTools.assert_called_once()
        self.assertIs(tools1, tools2)

    def test_elixir_tools_load_failure(self):
        """Test graceful handling of load failures."""
        stub = Mock()
        stub.GetExposedElixirTools.side_effect = Exception("RPC failed")

        ctx = SessionContext(stub, "test_session")

        # Should return empty dict on failure
        tools = ctx.elixir_tools
        self.assertEqual(tools, {})


class TestCallElixirTool(unittest.TestCase):
    """Test calling Elixir tools from Python."""

    def test_call_elixir_tool_success(self):
        """Test successful tool call."""
        stub = Mock()

        # Mock tools response
        tool_spec = ToolSpec(name="add", description="Add numbers")
        tools_response = GetExposedElixirToolsResponse()
        tools_response.tools["add"].CopyFrom(tool_spec)
        stub.GetExposedElixirTools.return_value = tools_response

        # Mock tool execution response
        result_any = ProtoAny()
        result_struct = Struct()
        result_struct["sum"] = 42
        result_any.Pack(result_struct)

        exec_response = ExecuteElixirToolResponse(
            success=True,
            result=result_any
        )
        stub.ExecuteElixirTool.return_value = exec_response

        ctx = SessionContext(stub, "test_session")

        # Call tool
        result = ctx.call_elixir_tool("add", a=10, b=32)

        # Verify RPC was called correctly
        stub.ExecuteElixirTool.assert_called_once()
        call_args = stub.ExecuteElixirTool.call_args[0][0]
        self.assertEqual(call_args.session_id, "test_session")
        self.assertEqual(call_args.tool_name, "add")

    def test_call_elixir_tool_not_found(self):
        """Test calling a tool that doesn't exist."""
        stub = Mock()
        stub.GetExposedElixirTools.return_value = GetExposedElixirToolsResponse()

        ctx = SessionContext(stub, "test_session")

        with self.assertRaises(ValueError) as cm:
            ctx.call_elixir_tool("nonexistent_tool")

        self.assertIn("not found", str(cm.exception))

    def test_call_elixir_tool_execution_failure(self):
        """Test handling of tool execution failures."""
        stub = Mock()

        # Mock tools
        tool_spec = ToolSpec(name="failing_tool")
        tools_response = GetExposedElixirToolsResponse()
        tools_response.tools["failing_tool"].CopyFrom(tool_spec)
        stub.GetExposedElixirTools.return_value = tools_response

        # Mock failed execution
        exec_response = ExecuteElixirToolResponse(
            success=False,
            error="Tool execution failed"
        )
        stub.ExecuteElixirTool.return_value = exec_response

        ctx = SessionContext(stub, "test_session")

        with self.assertRaises(RuntimeError) as cm:
            ctx.call_elixir_tool("failing_tool")

        self.assertIn("Tool execution failed", str(cm.exception))


class TestCleanup(unittest.TestCase):
    """Test SessionContext cleanup."""

    def test_cleanup_calls_rpc(self):
        """Test cleanup calls CleanupSession RPC."""
        stub = Mock()
        stub.CleanupSession.return_value = CleanupSessionResponse(
            success=True,
            resources_cleaned=0
        )

        ctx = SessionContext(stub, "test_session")
        ctx.cleanup()

        stub.CleanupSession.assert_called_once()
        call_args = stub.CleanupSession.call_args[0][0]
        self.assertEqual(call_args.session_id, "test_session")

    def test_cleanup_best_effort_on_error(self):
        """Test cleanup doesn't raise on errors."""
        stub = Mock()
        stub.CleanupSession.side_effect = Exception("RPC failed")

        ctx = SessionContext(stub, "test_session")

        # Should not raise
        ctx.cleanup()


class TestContextManager(unittest.TestCase):
    """Test SessionContext as context manager."""

    def test_context_manager_enter_exit(self):
        """Test context manager protocol."""
        stub = Mock()
        stub.CleanupSession.return_value = CleanupSessionResponse(success=True)

        with SessionContext(stub, "test_session") as ctx:
            self.assertIsInstance(ctx, SessionContext)
            self.assertEqual(ctx.session_id, "test_session")

        # Cleanup should be called on exit
        stub.CleanupSession.assert_called_once()

    def test_context_manager_cleanup_on_exception(self):
        """Test cleanup is called even when exception occurs."""
        stub = Mock()
        stub.CleanupSession.return_value = CleanupSessionResponse(success=True)

        try:
            with SessionContext(stub, "test_session") as ctx:
                raise ValueError("Test exception")
        except ValueError:
            pass

        # Cleanup should still be called
        stub.CleanupSession.assert_called_once()


if __name__ == '__main__':
    unittest.main()
