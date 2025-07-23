"""Variable operations handler for showcase adapter."""

from typing import Dict, Any, List, Optional
from ..tool import Tool


class VariableOpsHandler:
    """Handler for variable management operations.
    
    Note: In a production system with full SessionContext support,
    these would use ctx.register_variable(), ctx.get_variable(), etc.
    For this showcase, we use a simple in-memory approach.
    """
    
    # Simple in-memory storage for demo
    _variables = {}
    
    def get_tools(self) -> Dict[str, Tool]:
        """Return all tools provided by this handler."""
        return {
            "register_variable": Tool(self.register_variable),
            "get_variable": Tool(self.get_variable),
            "set_variable": Tool(self.set_variable),
            "set_variable_with_history": Tool(self.set_variable_with_history),
            "get_variables": Tool(self.get_variables),
            "set_variables": Tool(self.set_variables),
        }
    
    def register_variable(self, ctx, name: str, type: str, 
                         initial_value: Any, constraints: Dict) -> Dict[str, Any]:
        """Register a variable with type and constraints."""
        session_id = ctx.session_id
        
        if session_id not in self._variables:
            self._variables[session_id] = {}
        
        # Store variable with metadata
        var_id = f"{session_id}_{name}"
        self._variables[session_id][name] = {
            "id": var_id,
            "type": type,
            "value": initial_value,
            "constraints": constraints,
            "version": 1
        }
        
        return {
            "variable_id": var_id,
            "name": name,
            "type": type,
            "initial_value": initial_value
        }
    
    def get_variable(self, ctx, name: str) -> Dict[str, Any]:
        """Get a variable value."""
        session_id = ctx.session_id
        
        if session_id in self._variables and name in self._variables[session_id]:
            var_data = self._variables[session_id][name]
            return {
                "name": name,
                "value": var_data["value"]
            }
        else:
            raise KeyError(f"Variable '{name}' not found in session")
    
    def set_variable(self, ctx, name: str, value: Any) -> Dict[str, Any]:
        """Set a variable value."""
        session_id = ctx.session_id
        
        if session_id not in self._variables:
            self._variables[session_id] = {}
        
        if name in self._variables[session_id]:
            self._variables[session_id][name]["value"] = value
            self._variables[session_id][name]["version"] += 1
        else:
            # Auto-register if doesn't exist
            self._variables[session_id][name] = {
                "id": f"{session_id}_{name}",
                "type": "any",
                "value": value,
                "constraints": {},
                "version": 1
            }
        
        return {
            "name": name,
            "value": value,
            "success": True
        }
    
    def set_variable_with_history(self, ctx, name: str, value: Any, 
                                 metadata: Optional[Dict] = None) -> Dict[str, Any]:
        """Set variable with metadata for history tracking."""
        session_id = ctx.session_id
        
        # Get previous value
        previous = None
        if session_id in self._variables and name in self._variables[session_id]:
            previous = self._variables[session_id][name]["value"]
        
        # Update variable
        result = self.set_variable(ctx, name, value)
        
        return {
            "name": name,
            "value": value,
            "previous_value": previous,
            "metadata": metadata
        }
    
    def get_variables(self, ctx, names: List[str] = None, **kwargs) -> Dict[str, Any]:
        """Get multiple variables at once."""
        # Handle names being passed as keyword argument
        if names is None and 'names' in kwargs:
            names = kwargs['names']
            
        session_id = ctx.session_id
        values = {}
        
        if session_id in self._variables:
            for name in names:
                if name in self._variables[session_id]:
                    values[name] = self._variables[session_id][name]["value"]
        
        return {
            "variables": values,
            "count": len(values)
        }
    
    def set_variables(self, ctx, updates: Dict[str, Any] = None,
                     atomic: bool = False, **kwargs) -> Dict[str, Any]:
        """Set multiple variables at once."""
        # Handle updates being passed as keyword argument
        if updates is None and 'updates' in kwargs:
            updates = kwargs['updates']
            
        # Handle JSON-encoded updates
        if isinstance(updates, str):
            import json
            updates = json.loads(updates)
        
        results = {}
        successful = 0
        failed = 0
        
        for name, value in updates.items():
            try:
                self.set_variable(ctx, name, value)
                results[name] = True
                successful += 1
            except Exception as e:
                results[name] = str(e)
                failed += 1
                if atomic:
                    # Rollback on failure in atomic mode
                    break
        
        return {
            "total": len(updates),
            "updated_count": successful,
            "failed_count": failed,
            "successful": successful,
            "failed": failed,
            "results": results
        }