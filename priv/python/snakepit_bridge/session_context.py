"""
Minimal session context for Python adapters.

Provides lightweight session tracking and optional Elixir tool proxy.
The Elixir SessionStore handles all stateful session management (programs, metadata, TTL).
Python adapters just need the session_id to participate in stateful workflows.
"""

import logging
from typing import Dict, Any, Optional

from snakepit_bridge_pb2 import (
    CleanupSessionRequest,
    GetExposedElixirToolsRequest,
    ExecuteElixirToolRequest
)
from snakepit_bridge_pb2_grpc import BridgeServiceStub
from google.protobuf.struct_pb2 import Struct

logger = logging.getLogger(__name__)


class SessionContext:
    """
    Minimal session context for Python adapters.

    The Elixir side (SessionStore) manages all session state:
    - Programs (DSPy, ML models)
    - Metadata
    - TTL and expiration
    - Worker affinity

    Python adapters just need:
    - session_id: To identify the session
    - stub: gRPC client to call back to Elixir if needed
    - Optional: Elixir tool proxy for cross-language tool calls
    """

    def __init__(self, stub: BridgeServiceStub, session_id: str):
        """
        Initialize session context.

        Args:
            stub: gRPC stub for calling back to Elixir
            session_id: Unique session identifier
        """
        self.stub = stub
        self.session_id = session_id
        self._elixir_tools: Optional[Dict[str, Any]] = None
        logger.debug(f"SessionContext created for session {session_id}")

    @property
    def elixir_tools(self) -> Dict[str, Any]:
        """
        Lazy-load available Elixir tools.

        Returns:
            Dictionary of tool_name -> tool_spec
        """
        if self._elixir_tools is None:
            self._elixir_tools = self._load_elixir_tools()
        return self._elixir_tools

    def _load_elixir_tools(self) -> Dict[str, Any]:
        """
        Load exposed Elixir tools via gRPC.

        Returns:
            Dictionary of available Elixir tools
        """
        try:
            request = GetExposedElixirToolsRequest(session_id=self.session_id)
            response = self.stub.GetExposedElixirTools(request)

            tools = {}
            for tool_name, tool_spec in response.tools.items():
                tools[tool_name] = {
                    'name': tool_spec.name,
                    'description': tool_spec.description,
                    'parameters': dict(tool_spec.parameters)
                }

            logger.info(f"Loaded {len(tools)} Elixir tools for session {self.session_id}")
            return tools

        except Exception as e:
            logger.warning(f"Failed to load Elixir tools: {e}")
            return {}

    def call_elixir_tool(self, tool_name: str, **kwargs) -> Any:
        """
        Call an Elixir tool from Python.

        Args:
            tool_name: Name of the Elixir tool to call
            **kwargs: Tool parameters

        Returns:
            Tool execution result

        Raises:
            ValueError: If tool not found
            RuntimeError: If tool execution fails
        """
        if tool_name not in self.elixir_tools:
            available = list(self.elixir_tools.keys())
            raise ValueError(
                f"Elixir tool '{tool_name}' not found. "
                f"Available tools: {available}"
            )

        try:
            # Convert kwargs to protobuf Struct
            params_struct = Struct()
            for key, value in kwargs.items():
                if isinstance(value, (str, int, float, bool)):
                    params_struct[key] = value
                else:
                    params_struct[key] = str(value)

            request = ExecuteElixirToolRequest(
                session_id=self.session_id,
                tool_name=tool_name,
                parameters=params_struct
            )

            response = self.stub.ExecuteElixirTool(request)

            if not response.success:
                raise RuntimeError(f"Tool execution failed: {response.error}")

            # Convert protobuf Any to Python value
            result = response.result
            if result.Is(Struct.DESCRIPTOR):
                struct_result = Struct()
                result.Unpack(struct_result)
                return dict(struct_result)

            return result

        except Exception as e:
            logger.error(f"Error calling Elixir tool '{tool_name}': {e}")
            raise RuntimeError(f"Failed to call Elixir tool: {e}")

    def cleanup(self):
        """
        Cleanup session resources.

        This is a best-effort cleanup. The Elixir SessionStore
        will automatically clean up expired sessions via TTL.
        """
        try:
            request = CleanupSessionRequest(session_id=self.session_id)
            self.stub.CleanupSession(request)
            logger.debug(f"Session {self.session_id} cleaned up")
        except Exception as e:
            logger.debug(f"Session cleanup failed (best effort): {e}")

    def __enter__(self):
        """Context manager support."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager cleanup."""
        self.cleanup()
        return False

    def __repr__(self):
        return f"SessionContext(session_id='{self.session_id}')"
