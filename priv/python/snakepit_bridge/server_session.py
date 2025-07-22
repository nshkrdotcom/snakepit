"""
Server-side session management for the gRPC bridge.
"""

from typing import Any, Dict, List, Optional
from datetime import datetime
import uuid
import json
import logging

from .types import VariableType, TypeValidator, serialize_value, deserialize_value
from .snakepit_bridge_pb2 import Variable as ProtoVariable, OptimizationStatus
from google.protobuf.any_pb2 import Any as ProtoAny
from google.protobuf.timestamp_pb2 import Timestamp

logger = logging.getLogger(__name__)


class ServerVariable:
    """Server-side variable representation."""
    
    def __init__(self, id: str, name: str, var_type: str, value: Any, 
                 constraints: Dict[str, Any] = None, metadata: Dict[str, str] = None):
        self.id = id
        self.name = name
        self.type = var_type
        self.value = value
        self.constraints = constraints or {}
        self.metadata = metadata or {}
        self.version = 0
        self.created_at = datetime.now()
        self.last_updated_at = self.created_at
        self.optimization_status = None
        self.source = "PYTHON"
    
    def update(self, new_value: Any, metadata: Optional[Dict[str, str]] = None):
        """Update the variable value."""
        self.value = new_value
        self.version += 1
        self.last_updated_at = datetime.now()
        if metadata:
            self.metadata.update(metadata)
        

class ServerSession:
    """Server-side session management."""
    
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.variables: Dict[str, ServerVariable] = {}  # ID -> Variable
        self.name_to_id: Dict[str, str] = {}  # Name -> ID mapping
        self.tools: Dict[str, Dict[str, Any]] = {}
        self.created_at = datetime.now()
        
    def register_variable(self, name: str, var_type: str, initial_value: Any,
                         constraints: Optional[Dict[str, Any]] = None,
                         metadata: Optional[Dict[str, str]] = None) -> str:
        """Register a new variable in the session."""
        # Generate ID
        var_id = f"var_{name}_{uuid.uuid4().hex[:8]}"
        
        # Validate type
        try:
            type_enum = VariableType(var_type)
            validator = TypeValidator.get_validator(type_enum)
            validated_value = validator.validate(initial_value)
            
            # Validate constraints if any
            if constraints:
                validator.validate_constraints(validated_value, constraints)
        except Exception as e:
            raise ValueError(f"Validation failed: {e}")
        
        # Create variable
        variable = ServerVariable(
            id=var_id,
            name=name,
            var_type=var_type,
            value=validated_value,
            constraints=constraints,
            metadata=metadata
        )
        
        # Store
        self.variables[var_id] = variable
        self.name_to_id[name] = var_id
        
        logger.info(f"Registered variable {name} with ID {var_id}")
        return var_id
    
    def get_variable_by_id(self, var_id: str) -> Optional[ServerVariable]:
        """Get variable by ID."""
        return self.variables.get(var_id)
    
    def get_variable_by_name(self, name: str) -> Optional[ServerVariable]:
        """Get variable by name."""
        var_id = self.name_to_id.get(name)
        if var_id:
            return self.variables.get(var_id)
        return None
    
    def set_variable(self, identifier: str, new_value: Any, 
                    metadata: Optional[Dict[str, str]] = None) -> bool:
        """Update a variable value."""
        # Find variable
        variable = None
        if identifier.startswith("var_"):
            variable = self.get_variable_by_id(identifier)
        else:
            variable = self.get_variable_by_name(identifier)
        
        if not variable:
            return False
        
        try:
            # Validate new value
            type_enum = VariableType(variable.type)
            validator = TypeValidator.get_validator(type_enum)
            validated_value = validator.validate(new_value)
            
            # Validate constraints
            if variable.constraints:
                validator.validate_constraints(validated_value, variable.constraints)
            
            # Update
            variable.update(validated_value, metadata)
            return True
            
        except Exception as e:
            logger.error(f"Failed to set variable: {e}")
            return False
    
    def list_variables(self, pattern: Optional[str] = None) -> List[ServerVariable]:
        """List all variables or those matching a pattern."""
        variables = list(self.variables.values())
        
        if pattern:
            import re
            # Convert wildcard pattern to regex
            regex_pattern = pattern.replace('*', '.*')
            regex = re.compile(regex_pattern)
            variables = [v for v in variables if regex.match(v.name)]
        
        return variables
    
    def delete_variable(self, identifier: str) -> bool:
        """Delete a variable."""
        var_id = None
        if identifier.startswith("var_"):
            var_id = identifier if identifier in self.variables else None
        else:
            var_id = self.name_to_id.get(identifier)
        
        if var_id:
            variable = self.variables.pop(var_id, None)
            if variable:
                self.name_to_id.pop(variable.name, None)
                return True
        
        return False
    
    def get_tools(self) -> Dict[str, Dict[str, Any]]:
        """Get registered tools."""
        return self.tools
    
    def cleanup(self):
        """Clean up session resources."""
        self.variables.clear()
        self.name_to_id.clear()
        self.tools.clear()
        logger.info(f"Cleaned up session {self.session_id}")