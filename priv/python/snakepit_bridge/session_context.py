"""
SessionContext manages the Python-side session state.
"""

import asyncio
import time
import threading
from typing import Dict, Any, Optional, Tuple, List
from datetime import datetime, timedelta
import logging
import uuid

logger = logging.getLogger(__name__)


class SessionContext:
    """
    Manages session state and provides unified access to variables and tools.
    
    This is a minimal implementation for Stage 0. It will be significantly
    expanded in subsequent stages.
    """
    
    def __init__(self, session_id: str, config: Optional[Dict[str, Any]] = None):
        self.session_id = session_id
        self.config = config or {}
        
        # Configuration
        self._cache_enabled = self.config.get('enable_caching', True)
        self._cache_ttl = self.config.get('cache_ttl', 60)  # seconds
        self._telemetry_enabled = self.config.get('enable_telemetry', False)
        
        # Session metadata
        self.metadata: Dict[str, str] = self.config.get('metadata', {})
        self.created_at = datetime.utcnow()
        
        # State storage
        self._tools: Dict[str, Any] = {}
        self._variable_cache: Dict[str, Tuple[Any, float]] = {}
        self._local_objects: Dict[str, Any] = {}  # For DSPy modules, etc.
        
        # Variable storage
        self._variables: Dict[str, Dict[str, Any]] = {}  # id -> variable
        self._variables_by_name: Dict[str, str] = {}  # name -> id
        self._lock = threading.Lock()  # Thread safety
        
        # Statistics
        self._stats = {
            'cache_hits': 0,
            'cache_misses': 0,
            'tool_executions': 0,
            'variable_reads': 0,
            'variable_writes': 0
        }
        
        logger.info(f"SessionContext created: {session_id}")
    
    def get_session_id(self) -> str:
        """Get the session ID."""
        return self.session_id
    
    def set_metadata(self, key: str, value: str):
        """Set session metadata."""
        self.metadata[key] = value
    
    def get_metadata(self, key: str) -> Optional[str]:
        """Get session metadata."""
        return self.metadata.get(key)
    
    def get_tools(self) -> Dict[str, Any]:
        """Get available tools."""
        return self._tools.copy()
    
    def store_local_object(self, key: str, obj: Any):
        """Store a local object (e.g., DSPy module instance)."""
        self._local_objects[key] = obj
        logger.debug(f"Stored local object: {key}")
    
    def get_local_object(self, key: str) -> Any:
        """Retrieve a local object."""
        return self._local_objects.get(key)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get session statistics."""
        return {
            **self._stats,
            'session_id': self.session_id,
            'created_at': self.created_at.isoformat(),
            'uptime_seconds': (datetime.utcnow() - self.created_at).total_seconds(),
            'cache_enabled': self._cache_enabled,
            'telemetry_enabled': self._telemetry_enabled
        }
    
    async def cleanup(self):
        """Clean up session resources."""
        logger.info(f"Cleaning up session: {self.session_id}")
        
        # Clear caches
        self._variable_cache.clear()
        self._local_objects.clear()
        self._tools.clear()
        
        # Log final stats
        if self._telemetry_enabled:
            logger.info(f"Session stats: {self.get_stats()}")
    
    # Variable management methods
    
    def register_variable(self, name: str, var_type: str, initial_value: Any,
                         constraints: Optional[Dict] = None,
                         metadata: Optional[Dict[str, str]] = None) -> str:
        """Register a new variable."""
        from .serialization import TypeSerializer
        
        # Validate value against type and constraints
        if constraints:
            TypeSerializer.validate_constraints(initial_value, var_type, constraints)
        
        var_id = f"var_{uuid.uuid4().hex[:8]}"
        
        variable = {
            'id': var_id,
            'name': name,
            'type': var_type,
            'value': initial_value,
            'constraints': constraints or {},
            'metadata': metadata or {},
            'version': 1,
            'created_at': datetime.utcnow(),
            'updated_at': datetime.utcnow()
        }
        
        with self._lock:
            if name in self._variables_by_name:
                raise ValueError(f"Variable '{name}' already exists")
            
            self._variables[var_id] = variable
            self._variables_by_name[name] = var_id
            
            self._stats['variable_writes'] += 1
        
        logger.info(f"Registered variable: {name} (ID: {var_id}, Type: {var_type})")
        return var_id
    
    def get_variable_by_id(self, var_id: str) -> Optional[Dict]:
        """Get variable by ID."""
        with self._lock:
            self._stats['variable_reads'] += 1
            return self._variables.get(var_id)
    
    def get_variable_by_name(self, name: str) -> Optional[Dict]:
        """Get variable by name."""
        with self._lock:
            var_id = self._variables_by_name.get(name)
            if var_id:
                self._stats['variable_reads'] += 1
                return self._variables.get(var_id)
            return None
    
    def set_variable(self, name: str, value: Any, 
                    metadata: Optional[Dict[str, str]] = None) -> bool:
        """Set variable value."""
        from .serialization import TypeSerializer
        
        with self._lock:
            var_id = self._variables_by_name.get(name)
            if not var_id:
                return False
            
            variable = self._variables.get(var_id)
            if not variable:
                return False
            
            # Validate against type and constraints
            if variable.get('constraints'):
                TypeSerializer.validate_constraints(value, variable['type'], variable['constraints'])
            
            old_value = variable['value']
            variable['value'] = value
            variable['version'] += 1
            variable['updated_at'] = datetime.utcnow()
            
            if metadata:
                variable['metadata'].update(metadata)
            
            self._stats['variable_writes'] += 1
            
            # TODO: Notify watchers in Stage 3
            
        logger.info(f"Updated variable: {name} (version: {variable['version']})")
        return True
    
    def list_variables(self) -> List[Dict]:
        """List all variables in the session."""
        with self._lock:
            return list(self._variables.values())
    
    # Placeholder methods for future stages
    
    async def execute_tool(self, name: str, parameters: Dict[str, Any]) -> Any:
        """Execute a tool - to be implemented in Stage 2."""
        raise NotImplementedError("Tools not implemented until Stage 2")
    
    async def watch_variables(self, names: List[str]):
        """Watch variables for changes - to be implemented in Stage 3."""
        raise NotImplementedError("Variable watching not implemented until Stage 3")