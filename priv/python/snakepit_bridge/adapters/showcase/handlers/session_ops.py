"""Session operations handler for showcase adapter."""

import time
import os
from datetime import datetime
from typing import Dict, Any
from ..tool import Tool


class SessionOpsHandler:
    """Handler for session management operations."""
    
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
        """Initialize session state in Elixir's SessionStore."""
        # Store all state in SessionContext (backed by Elixir)
        ctx['session_start_time'] = time.time()
        ctx['command_count'] = 0
        ctx['counter'] = 0
        
        return {
            "timestamp": datetime.now().isoformat(),
            "worker_pid": os.getpid(),
            "session_id": ctx.session_id
        }
    
    def cleanup_session(self, ctx) -> Dict[str, Any]:
        """Clean up session, demonstrating state retrieval."""
        # Retrieve state from SessionContext
        try:
            start_time = ctx['session_start_time']
        except:
            start_time = time.time()
        
        duration_ms = (time.time() - start_time) * 1000
        
        try:
            command_count = ctx['command_count']
        except:
            command_count = 0
        
        # Note: Actual cleanup happens in Elixir when session ends
        return {
            "duration_ms": round(duration_ms, 2),
            "command_count": command_count
        }
    
    def set_counter(self, ctx, value: int) -> Dict[str, Any]:
        """Set counter value via SessionContext."""
        ctx['counter'] = value
        
        # Increment command count
        command_count = ctx.get_variable('command_count') if 'command_count' in ctx else 0
        ctx['command_count'] = command_count + 1
        
        return {"value": value}
    
    def get_counter(self, ctx) -> Dict[str, Any]:
        """Get counter value from SessionContext."""
        # Increment command count
        command_count = ctx.get_variable('command_count') if 'command_count' in ctx else 0
        ctx['command_count'] = command_count + 1
        
        # Get counter value
        counter_value = ctx.get_variable('counter') if 'counter' in ctx else 0
        return {"value": counter_value}
    
    def increment_counter(self, ctx) -> Dict[str, Any]:
        """Demonstrate atomic counter increment via SessionContext."""
        # Get current values
        counter = ctx.get_variable('counter') if 'counter' in ctx else 0
        command_count = ctx.get_variable('command_count') if 'command_count' in ctx else 0
        
        # Increment
        new_counter = counter + 1
        new_command_count = command_count + 1
        
        # Store back
        ctx['counter'] = new_counter
        ctx['command_count'] = new_command_count
        
        return {"value": new_counter}
    
    def get_worker_info(self, ctx, call_number: int) -> Dict[str, Any]:
        """Get worker info and update command count."""
        # Increment command count
        command_count = ctx.get_variable('command_count') if 'command_count' in ctx else 0
        ctx['command_count'] = command_count + 1
        
        return {
            "worker_pid": str(os.getpid()),
            "call_number": call_number,
            "session_id": ctx.session_id
        }