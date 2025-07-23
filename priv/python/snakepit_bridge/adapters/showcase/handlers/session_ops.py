"""Session operations handler for showcase adapter."""

import time
import os
from datetime import datetime
from typing import Dict, Any
from ..tool import Tool


class SessionOpsHandler:
    """Handler for session management operations.
    
    Note: In a production system, state would be stored via SessionContext
    variables. For this showcase, we use a simple in-memory approach to
    demonstrate the concepts.
    """
    
    # Temporary in-memory storage for demo purposes
    # In production, use ctx.register_variable() or external storage
    _session_data = {}
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "init_session": Tool(self.init_session),
            "cleanup": Tool(self.cleanup_session),
            "set_counter": Tool(self.set_counter),
            "get_counter": Tool(self.get_counter),
            "increment_counter": Tool(self.increment_counter),
            "get_worker_info": Tool(self.get_worker_info)
        }
    
    def init_session(self, ctx, **kwargs) -> Dict[str, Any]:
        """Initialize session state."""
        session_id = ctx.session_id
        
        # Store initial state
        self._session_data[session_id] = {
            'session_start_time': time.time(),
            'command_count': 0,
            'counter': 0
        }
        
        return {
            "timestamp": datetime.now().isoformat(),
            "worker_pid": os.getpid(),
            "session_id": session_id
        }
    
    def cleanup_session(self, ctx) -> Dict[str, Any]:
        """Clean up session, demonstrating state retrieval."""
        session_id = ctx.session_id
        session_data = self._session_data.get(session_id, {})
        
        start_time = session_data.get('session_start_time', time.time())
        duration_ms = (time.time() - start_time) * 1000
        command_count = session_data.get('command_count', 0)
        
        # Cleanup
        if session_id in self._session_data:
            del self._session_data[session_id]
        
        return {
            "duration_ms": round(duration_ms, 2),
            "command_count": command_count
        }
    
    def set_counter(self, ctx, value: int) -> Dict[str, Any]:
        """Set counter value."""
        session_id = ctx.session_id
        if session_id not in self._session_data:
            self._session_data[session_id] = {'command_count': 0, 'counter': 0}
        
        self._session_data[session_id]['counter'] = value
        self._session_data[session_id]['command_count'] += 1
        
        return {"value": value}
    
    def get_counter(self, ctx) -> Dict[str, Any]:
        """Get counter value."""
        session_id = ctx.session_id
        session_data = self._session_data.get(session_id, {'command_count': 0, 'counter': 0})
        
        # Increment command count
        if session_id in self._session_data:
            self._session_data[session_id]['command_count'] += 1
        
        return {"value": session_data.get('counter', 0)}
    
    def increment_counter(self, ctx) -> Dict[str, Any]:
        """Demonstrate counter increment."""
        session_id = ctx.session_id
        if session_id not in self._session_data:
            self._session_data[session_id] = {'command_count': 0, 'counter': 0}
        
        # Increment both counters
        self._session_data[session_id]['counter'] += 1
        self._session_data[session_id]['command_count'] += 1
        
        return {"value": self._session_data[session_id]['counter']}
    
    def get_worker_info(self, ctx, call_number: int) -> Dict[str, Any]:
        """Get worker info and update command count."""
        session_id = ctx.session_id
        if session_id in self._session_data:
            self._session_data[session_id]['command_count'] += 1
        
        return {
            "worker_pid": str(os.getpid()),
            "call_number": call_number,
            "session_id": session_id
        }