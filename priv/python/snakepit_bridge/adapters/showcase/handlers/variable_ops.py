"""Variable operations handler for showcase adapter."""

from typing import Dict, Any, List, Optional
from ..tool import Tool


class VariableOpsHandler:
    """Handler for variable management operations."""
    
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
        # Register with SessionContext
        var_id = ctx.register_variable(name, type, initial_value, constraints)
        
        return {
            "variable_id": var_id,
            "name": name,
            "type": type,
            "initial_value": initial_value
        }
    
    def get_variable(self, ctx, name: str) -> Dict[str, Any]:
        """Get a variable value."""
        value = ctx.get_variable(name)
        return {
            "name": name,
            "value": value
        }
    
    def set_variable(self, ctx, name: str, value: Any) -> Dict[str, Any]:
        """Set a variable value."""
        ctx.update_variable(name, value)
        return {
            "name": name,
            "value": value,
            "success": True
        }
    
    def set_variable_with_history(self, ctx, name: str, value: Any, 
                                 metadata: Optional[Dict] = None) -> Dict[str, Any]:
        """Set variable with metadata for history tracking."""
        # Get previous value for history
        try:
            previous = ctx.get_variable(name)
        except:
            previous = None
        
        # Update with metadata
        ctx.update_variable(name, value, metadata=metadata)
        
        return {
            "name": name,
            "value": value,
            "previous_value": previous,
            "metadata": metadata
        }
    
    def get_variables(self, ctx, names: List[str]) -> Dict[str, Any]:
        """Get multiple variables at once."""
        values = ctx.get_variables(names)
        return {
            "variables": values,
            "count": len(values)
        }
    
    def set_variables(self, ctx, updates: Dict[str, Any], 
                     atomic: bool = False) -> Dict[str, Any]:
        """Set multiple variables at once."""
        results = ctx.update_variables(updates, atomic=atomic)
        
        successful = sum(1 for v in results.values() if v is True)
        failed = len(results) - successful
        
        return {
            "total": len(updates),
            "successful": successful,
            "failed": failed,
            "results": results
        }