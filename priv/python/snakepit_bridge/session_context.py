"""
Enhanced SessionContext with comprehensive variable support and intelligent caching.
"""

from typing import Any, Dict, List, Optional, Union, TypeVar, Generic
from contextlib import contextmanager
from datetime import datetime, timedelta
from threading import Lock
import weakref
import logging
import json
from dataclasses import dataclass, field
from enum import Enum

from .grpc.snakepit_bridge_pb2 import (
    Variable, RegisterVariableRequest, RegisterVariableResponse,
    GetVariableRequest, GetVariableResponse, SetVariableRequest, SetVariableResponse,
    BatchGetVariablesRequest, BatchGetVariablesResponse,
    BatchSetVariablesRequest, BatchSetVariablesResponse,
    ListVariablesRequest, ListVariablesResponse,
    DeleteVariableRequest, DeleteVariableResponse,
    OptimizationStatus
)
from .grpc.snakepit_bridge_pb2_grpc import BridgeServiceStub
from google.protobuf.any_pb2 import Any
from .types import (
    VariableType, 
    TypeValidator,
    serialize_value,
    deserialize_value,
    validate_constraints
)

logger = logging.getLogger(__name__)

T = TypeVar('T')

@dataclass
class CachedVariable:
    """Cached variable with TTL tracking."""
    variable: Variable
    cached_at: datetime
    ttl: timedelta = field(default_factory=lambda: timedelta(seconds=5))
    
    @property
    def expired(self) -> bool:
        return datetime.now() > self.cached_at + self.ttl
    
    def refresh(self, variable: Variable):
        self.variable = variable
        self.cached_at = datetime.now()


class VariableNotFoundError(KeyError):
    """Raised when a variable is not found."""
    pass


class VariableProxy(Generic[T]):
    """
    Proxy object for lazy variable access.
    
    Provides attribute-style access to variable values with
    automatic synchronization.
    """
    
    def __init__(self, context: 'SessionContext', name: str):
        self._context = weakref.ref(context)
        self._name = name
        self._lock = Lock()
    
    @property
    def value(self) -> T:
        """Get the current value."""
        ctx = self._context()
        if ctx is None:
            raise RuntimeError("SessionContext has been destroyed")
        return ctx.get_variable(self._name)
    
    @value.setter
    def value(self, new_value: T):
        """Update the value."""
        ctx = self._context()
        if ctx is None:
            raise RuntimeError("SessionContext has been destroyed")
        ctx.update_variable(self._name, new_value)
    
    def __repr__(self):
        try:
            return f"<Variable {self._name}={self.value}>"
        except:
            return f"<Variable {self._name} (not loaded)>"


class SessionContext:
    """
    Enhanced session context with comprehensive variable support.
    
    Provides intuitive Python API for variable management with
    intelligent caching to minimize gRPC calls.
    """
    
    def __init__(self, stub: BridgeServiceStub, session_id: str, strict_mode: bool = False):
        self.stub = stub
        self.session_id = session_id
        self._cache: Dict[str, CachedVariable] = {}
        self._cache_lock = Lock()
        self._default_ttl = timedelta(seconds=5)
        self._proxies: Dict[str, VariableProxy] = {}
        self.strict_mode = strict_mode
        
        # Tool registry remains from Stage 0
        self._tools = {}
        
        logger.info(f"Created SessionContext for session {session_id} (strict_mode={strict_mode})")
    
    def __enter__(self):
        """Support using SessionContext as a context manager."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Automatically cleanup when exiting context."""
        self.cleanup()
        return False
    
    # Variable Registration
    
    def register_variable(
        self,
        name: str,
        var_type: Union[str, VariableType],
        initial_value: Any,
        constraints: Optional[Dict[str, Any]] = None,
        metadata: Optional[Dict[str, str]] = None,
        ttl: Optional[timedelta] = None
    ) -> str:
        """
        Register a new variable in the session.
        
        Args:
            name: Variable name (must be unique in session)
            var_type: Type of the variable
            initial_value: Initial value
            constraints: Type-specific constraints
            metadata: Additional metadata
            ttl: Cache TTL for this variable
            
        Returns:
            Variable ID
            
        Raises:
            ValueError: If type validation fails
            RuntimeError: If registration fails
        """
        # Convert type
        if isinstance(var_type, str):
            var_type = VariableType[var_type.upper()]
        
        # Validate value against type
        validator = TypeValidator.get_validator(var_type)
        validated_value = validator.validate(initial_value)
        
        # Validate constraints if provided
        if constraints:
            validate_constraints(validated_value, var_type, constraints)
        
        # Serialize for gRPC
        value_any, binary_data = serialize_value(validated_value, var_type)
        
        # Convert constraints to JSON
        import json
        constraints_json = json.dumps(constraints) if constraints else ""
        
        request = RegisterVariableRequest(
            session_id=self.session_id,
            name=name,
            type=var_type.value,
            initial_value=value_any,
            constraints_json=constraints_json,
            metadata=metadata or {},
            initial_binary_value=binary_data if binary_data else b""
        )
        
        response = self.stub.RegisterVariable(request)
        
        if not response.success:
            raise RuntimeError(f"Failed to register variable: {response.error_message}")
        
        var_id = response.variable_id
        logger.info(f"Registered variable {name} ({var_id}) of type {var_type}")
        
        # Invalidate cache for this name
        self._invalidate_cache(name)
        
        return var_id
    
    # Variable Access
    
    def get_variable(self, identifier: str) -> Any:
        """
        Get a variable's value by name or ID.
        
        Uses cache when possible to minimize gRPC calls.
        
        Args:
            identifier: Variable name or ID
            
        Returns:
            The variable's current value
            
        Raises:
            VariableNotFoundError: If variable doesn't exist
        """
        # Check cache first
        with self._cache_lock:
            cached = self._cache.get(identifier)
            if cached and not cached.expired:
                logger.debug(f"Cache hit for variable {identifier}")
                return deserialize_value(
                    cached.variable.value, 
                    VariableType(cached.variable.type)
                )
        
        # Cache miss - fetch from server
        logger.debug(f"Cache miss for variable {identifier}")
        
        request = GetVariableRequest(
            session_id=self.session_id,
            variable_identifier=identifier
        )
        
        try:
            response = self.stub.GetVariable(request)
        except Exception as e:
            if "not found" in str(e).lower():
                raise VariableNotFoundError(f"Variable not found: {identifier}")
            raise
        
        variable = response.variable
        
        # Update cache (by both ID and name)
        with self._cache_lock:
            cached_var = CachedVariable(
                variable=variable,
                cached_at=datetime.now(),
                ttl=self._default_ttl
            )
            self._cache[variable.id] = cached_var
            self._cache[variable.name] = cached_var
        
        # Deserialize and return value
        return deserialize_value(
            variable.value,
            VariableType(variable.type),
            variable.binary_value if variable.binary_value else None
        )
    
    def update_variable(
        self,
        identifier: str,
        new_value: Any,
        metadata: Optional[Dict[str, str]] = None
    ) -> None:
        """
        Update a variable's value.
        
        Performs write-through caching for consistency.
        
        Args:
            identifier: Variable name or ID
            new_value: New value (will be validated)
            metadata: Additional metadata for the update
            
        Raises:
            ValueError: If value doesn't match type/constraints
            VariableNotFoundError: If variable doesn't exist
        """
        # First get the variable to know its type
        # This also populates the cache
        self.get_variable(identifier)
        
        # Get from cache to access type info
        with self._cache_lock:
            cached = self._cache.get(identifier)
            if not cached:
                raise RuntimeError("Variable should be in cache")
            
            var_type = VariableType(cached.variable.type)
        
        # Validate new value
        validator = TypeValidator.get_validator(var_type)
        validated_value = validator.validate(new_value)
        
        # Serialize for gRPC
        value_any, binary_data = serialize_value(validated_value, var_type)
        
        request = SetVariableRequest(
            session_id=self.session_id,
            variable_identifier=identifier,
            value=value_any,
            metadata=metadata or {},
            binary_value=binary_data if binary_data else b""
        )
        
        response = self.stub.SetVariable(request)
        
        if not response.success:
            raise RuntimeError(f"Failed to update variable: {response.error_message}")
        
        # Invalidate cache for write-through consistency
        self._invalidate_cache(identifier)
        
        logger.info(f"Updated variable {identifier}")
    
    def list_variables(self, pattern: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        List all variables or those matching a pattern.
        
        Args:
            pattern: Optional wildcard pattern (e.g., "temp_*")
            
        Returns:
            List of variable info dictionaries
        """
        request = ListVariablesRequest(
            session_id=self.session_id,
            pattern=pattern or ""
        )
        
        response = self.stub.ListVariables(request)
        
        variables = []
        for var in response.variables:
            var_type = VariableType(var.type)
            variables.append({
                'id': var.id,
                'name': var.name,
                'type': var_type.value,
                'value': deserialize_value(var.value, var_type),
                'version': var.version,
                'constraints': json.loads(var.constraints_json) if var.constraints_json else {},
                'metadata': dict(var.metadata),
                'optimizing': var.optimization_status.optimizing if var.optimization_status else False
            })
            
            # Update cache opportunistically
            with self._cache_lock:
                cached_var = CachedVariable(
                    variable=var,
                    cached_at=datetime.now(),
                    ttl=self._default_ttl
                )
                self._cache[var.id] = cached_var
                self._cache[var.name] = cached_var
        
        return variables
    
    def delete_variable(self, identifier: str) -> None:
        """
        Delete a variable from the session.
        
        Args:
            identifier: Variable name or ID
            
        Raises:
            RuntimeError: If deletion fails
        """
        request = DeleteVariableRequest(
            session_id=self.session_id,
            variable_identifier=identifier
        )
        
        response = self.stub.DeleteVariable(request)
        
        if not response.success:
            raise RuntimeError(f"Failed to delete variable: {response.error_message}")
        
        # Remove from cache
        self._invalidate_cache(identifier)
        
        # Remove proxy if exists
        self._proxies.pop(identifier, None)
        
        logger.info(f"Deleted variable {identifier}")
    
    # Batch Operations
    
    def get_variables(self, identifiers: List[str]) -> Dict[str, Any]:
        """
        Get multiple variables efficiently.
        
        Uses cache and batches uncached requests.
        
        Args:
            identifiers: List of variable names or IDs
            
        Returns:
            Dict mapping identifier to value
        """
        result = {}
        uncached = []
        
        # Check cache first
        with self._cache_lock:
            for identifier in identifiers:
                cached = self._cache.get(identifier)
                if cached and not cached.expired:
                    var_type = VariableType(cached.variable.type)
                    result[identifier] = deserialize_value(
                        cached.variable.value,
                        var_type
                    )
                else:
                    uncached.append(identifier)
        
        # Batch fetch uncached
        if uncached:
            request = BatchGetVariablesRequest(
                session_id=self.session_id,
                variable_identifiers=uncached
            )
            
            response = self.stub.GetVariables(request)
            
            # Process found variables
            for var_id, var in response.variables.items():
                var_type = VariableType(var.type)
                value = deserialize_value(var.value, var_type, var.binary_value if var.binary_value else None)
                
                # Update result
                result[var_id] = value
                result[var.name] = value
                
                # Update cache
                with self._cache_lock:
                    cached_var = CachedVariable(
                        variable=var,
                        cached_at=datetime.now(),
                        ttl=self._default_ttl
                    )
                    self._cache[var.id] = cached_var
                    self._cache[var.name] = cached_var
            
            # Handle missing
            for missing in response.missing_variables:
                if missing in identifiers:
                    raise VariableNotFoundError(f"Variable not found: {missing}")
        
        return result
    
    def update_variables(
        self,
        updates: Dict[str, Any],
        atomic: bool = False,
        metadata: Optional[Dict[str, str]] = None
    ) -> Dict[str, Union[bool, str]]:
        """
        Update multiple variables efficiently.
        
        Args:
            updates: Dict mapping identifier to new value
            atomic: If True, all updates must succeed
            metadata: Metadata for all updates
            
        Returns:
            Dict mapping identifier to success/error
        """
        # First, get all variables to know their types
        var_info = self.get_variables(list(updates.keys()))
        
        # Prepare updates with proper serialization
        serialized_updates = {}
        binary_updates = {}
        for identifier, new_value in updates.items():
            # Get variable type from cache
            with self._cache_lock:
                cached = self._cache.get(identifier)
                if not cached:
                    continue
                var_type = VariableType(cached.variable.type)
            
            # Validate and serialize
            validator = TypeValidator.get_validator(var_type)
            validated = validator.validate(new_value)
            value_any, binary_data = serialize_value(validated, var_type)
            serialized_updates[identifier] = value_any
            if binary_data:
                binary_updates[identifier] = binary_data
        
        request = BatchSetVariablesRequest(
            session_id=self.session_id,
            updates=serialized_updates,
            atomic=atomic,
            metadata=metadata or {},
            binary_updates=binary_updates
        )
        
        response = self.stub.SetVariables(request)
        
        if not response.success:
            # Return errors
            return {k: v for k, v in response.errors.items()}
        
        # Process results
        results = {}
        for identifier in updates:
            if identifier in response.errors:
                results[identifier] = response.errors[identifier]
            else:
                results[identifier] = True
                # Invalidate cache
                self._invalidate_cache(identifier)
        
        return results
    
    # Pythonic Access Patterns
    
    def __getitem__(self, name: str) -> Any:
        """Allow dict-style access: value = ctx['temperature']"""
        return self.get_variable(name)
    
    def __setitem__(self, name: str, value: Any):
        """
        Allow dict-style updates: ctx['temperature'] = 0.8
        
        In strict mode, only allows updating existing variables.
        In normal mode, auto-registers new variables.
        """
        try:
            self.update_variable(name, value)
        except VariableNotFoundError:
            if self.strict_mode:
                raise VariableNotFoundError(
                    f"Variable '{name}' not found. In strict mode, variables must be explicitly "
                    f"registered with register_variable() before assignment."
                )
            # Auto-register if doesn't exist (non-strict mode)
            var_type = TypeValidator.infer_type(value)
            self.register_variable(name, var_type, value)
    
    def __contains__(self, name: str) -> bool:
        """Check if variable exists: 'temperature' in ctx"""
        try:
            self.get_variable(name)
            return True
        except VariableNotFoundError:
            return False
    
    @property
    def v(self) -> 'VariableNamespace':
        """
        Attribute-style access to variables.
        
        Example:
            ctx.v.temperature = 0.8
            print(ctx.v.temperature)
        """
        return VariableNamespace(self)
    
    def variable(self, name: str) -> VariableProxy:
        """
        Get a variable proxy for repeated access.
        
        The proxy provides efficient access to a single variable.
        """
        if name not in self._proxies:
            self._proxies[name] = VariableProxy(self, name)
        return self._proxies[name]
    
    @contextmanager
    def batch_updates(self):
        """
        Context manager for batched updates.
        
        Example:
            with ctx.batch_updates() as batch:
                batch['var1'] = 10
                batch['var2'] = 20
                batch['var3'] = 30
        """
        batch = BatchUpdater(self)
        yield batch
        batch.commit()
    
    # Cache Management
    
    def set_cache_ttl(self, ttl: timedelta):
        """Set default cache TTL for variables."""
        self._default_ttl = ttl
    
    def clear_cache(self):
        """Clear all cached variables."""
        with self._cache_lock:
            self._cache.clear()
        logger.info("Cleared variable cache")
    
    def _invalidate_cache(self, identifier: str):
        """Invalidate cache entry for a variable."""
        with self._cache_lock:
            # Try to remove by identifier
            self._cache.pop(identifier, None)
            
            # Also check if it's cached by the other key
            to_remove = []
            for key, cached in self._cache.items():
                if cached.variable.id == identifier or cached.variable.name == identifier:
                    to_remove.append(key)
            
            for key in to_remove:
                self._cache.pop(key, None)
    
    def _deserialize_constraints(self, constraints_json: str) -> Dict[str, Any]:
        """Deserialize constraint values."""
        if not constraints_json:
            return {}
        import json
        try:
            return json.loads(constraints_json)
        except:
            return {}
    
    def cleanup(self, force: bool = False):
        """
        Clean up resources associated with this session context.
        
        This method:
        1. Clears local caches and proxies
        2. Sends a CleanupSession RPC to the server to release server-side resources
        
        Args:
            force: If True, forces cleanup even if there are active references
        """
        # Clear local resources first
        self.clear_cache()
        self._proxies.clear()
        
        # Send cleanup request to server
        try:
            from .grpc.snakepit_bridge_pb2 import CleanupSessionRequest
            
            request = CleanupSessionRequest(
                session_id=self.session_id,
                force=force
            )
            
            response = self.stub.CleanupSession(request)
            
            if response.success:
                logger.info(f"Successfully cleaned up session {self.session_id} "
                          f"(cleaned {response.resources_cleaned} resources)")
            else:
                logger.warning(f"Failed to cleanup session {self.session_id} on server")
                
        except Exception as e:
            logger.error(f"Error during session cleanup: {e}")
        
        logger.info(f"Cleaned up session context for {self.session_id}")
    
    # Existing tool methods remain...
    
    def register_tool(self, tool_class):
        """Register a tool (from Stage 0)."""
        # Implementation remains from Stage 0
        pass
    
    def call_tool(self, tool_name: str, **kwargs):
        """Call a tool (from Stage 0)."""
        # Implementation remains from Stage 0
        pass


class VariableNamespace:
    """
    Namespace for attribute-style variable access.
    
    Provides ctx.v.variable_name syntax.
    """
    
    def __init__(self, context: SessionContext):
        self._context = weakref.ref(context)
    
    def __getattr__(self, name: str) -> Any:
        ctx = self._context()
        if ctx is None:
            raise RuntimeError("SessionContext has been destroyed")
        return ctx.get_variable(name)
    
    def __setattr__(self, name: str, value: Any):
        if name.startswith('_'):
            super().__setattr__(name, value)
        else:
            ctx = self._context()
            if ctx is None:
                raise RuntimeError("SessionContext has been destroyed")
            try:
                ctx.update_variable(name, value)
            except VariableNotFoundError:
                # Auto-register
                var_type = TypeValidator.infer_type(value)
                ctx.register_variable(name, var_type, value)


class BatchUpdater:
    """Collect updates for batch submission."""
    
    def __init__(self, context: SessionContext):
        self.context = context
        self.updates = {}
    
    def __setitem__(self, name: str, value: Any):
        self.updates[name] = value
    
    def commit(self, atomic: bool = False):
        """Commit all updates."""
        if self.updates:
            return self.context.update_variables(self.updates, atomic=atomic)
        return {}