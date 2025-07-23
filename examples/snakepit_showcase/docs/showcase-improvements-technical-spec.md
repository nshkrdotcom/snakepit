# Snakepit Showcase Improvements: Technical Specification

## Overview

This document provides a detailed technical specification for improving the `snakepit_showcase` application to better demonstrate production-ready patterns and best practices for the Snakepit system. The improvements focus on four key areas:

1. **State Management Architecture** - Refactoring to use Elixir's SessionStore exclusively
2. **Python Code Organization** - Breaking up the monolithic adapter
3. **Error Handling Patterns** - Demonstrating resilient code practices
4. **API Usage Clarity** - Better documentation of when to use different execution modes

## Current Architecture Analysis

### State Management Issues

The current implementation in [`lib/snakepit_showcase/python_adapters/showcase_adapter.py`](../lib/snakepit_showcase/python_adapters/showcase_adapter.py) violates Snakepit's core architectural principle by maintaining state in Python:

```python
class ShowcaseAdapter:
    # State persists across requests within the same worker process
    session_start_times = {}
    command_counts = {}
    counters = {}
```

This approach has several problems:
- **Violates stateless worker principle**: Python workers should be computation-only
- **Memory leaks**: State accumulates without bounds
- **No persistence**: State is lost if worker crashes
- **No sharing**: State isn't visible across workers
- **Race conditions**: No atomic operations or locking

### Current State Usage Locations

1. **Session Management** (lines 174-200 in `showcase_adapter.py`):
   - `init_session`: Stores start time in class variable
   - `cleanup_session`: Removes session data
   - Uses: `session_start_times`, `command_counts`, `counters`

2. **Counter Operations** (lines 202-214):
   - `set_counter`, `get_counter`, `increment_counter`
   - Direct manipulation of `counters` dictionary

3. **ML Workflow State** (lines 393-552):
   - `ml_data` dictionary stores training data
   - `ml_models` dictionary stores trained models

## Proposed Architecture

### Core Principle: Elixir Owns State

All persistent state should be managed through Elixir's SessionStore using the SessionContext API. Python workers should be purely functional transformations.

### State Management Refactoring

#### 1. Session Management Refactoring

**Current Implementation:**
```python
def init_session(self, ctx: SessionContext, **kwargs) -> Dict[str, Any]:
    session_id = ctx.session_id
    ShowcaseAdapter.session_start_times[session_id] = time.time()
    ShowcaseAdapter.command_counts[session_id] = 0
    ShowcaseAdapter.counters[session_id] = 0
```

**Proposed Implementation:**
```python
def init_session(self, ctx: SessionContext, **kwargs) -> Dict[str, Any]:
    # Store all session state in Elixir via SessionContext
    ctx.set("session_start_time", time.time())
    ctx.set("command_count", 0)
    ctx.set("counter", 0)
    
    return {
        "timestamp": datetime.now().isoformat(),
        "worker_pid": os.getpid(),
        "session_id": ctx.session_id
    }
```

**File Changes Required:**
- [`priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py`](../../priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py): Lines 174-200

#### 2. Counter Operations Refactoring

**Current Implementation:**
```python
def increment_counter(self, ctx: SessionContext) -> Dict[str, Any]:
    ShowcaseAdapter.counters[ctx.session_id] = ShowcaseAdapter.counters.get(ctx.session_id, 0) + 1
    ShowcaseAdapter.command_counts[ctx.session_id] = ShowcaseAdapter.command_counts.get(ctx.session_id, 0) + 1
    return {"value": ShowcaseAdapter.counters[ctx.session_id]}
```

**Proposed Implementation:**
```python
def increment_counter(self, ctx: SessionContext) -> Dict[str, Any]:
    # Atomic increment using SessionContext
    current_value = ctx.get("counter", 0)
    new_value = current_value + 1
    ctx.set("counter", new_value)
    
    # Update command count
    command_count = ctx.get("command_count", 0)
    ctx.set("command_count", command_count + 1)
    
    return {"value": new_value}
```

**File Changes Required:**
- [`priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py`](../../priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py): Lines 202-214

#### 3. ML Workflow State Refactoring

**Current Implementation:**
```python
def load_sample_data(self, ctx: SessionContext, dataset: str, split: float) -> Dict[str, Any]:
    # Store in instance variable
    self.ml_data[session_id] = {
        "X_train": np.random.randn(train_samples, 4),
        "y_train": np.random.randint(0, 3, train_samples),
        ...
    }
```

**Proposed Implementation:**
```python
def load_sample_data(self, ctx: SessionContext, dataset: str, split: float) -> Dict[str, Any]:
    # Generate data
    train_data = {
        "X_train": np.random.randn(train_samples, 4).tolist(),  # Convert to list for JSON
        "y_train": np.random.randint(0, 3, train_samples).tolist(),
        "X_test": np.random.randn(test_samples, 4).tolist(),
        "y_test": np.random.randint(0, 3, test_samples).tolist(),
        "feature_names": ["sepal_length", "sepal_width", "petal_length", "petal_width"]
    }
    
    # Store in SessionContext as tensor variables
    ctx.register_variable("ml_train_data", "tensor", {
        "shape": [train_samples, 4],
        "data": train_data["X_train"]
    })
    ctx.register_variable("ml_train_labels", "integer_list", train_data["y_train"])
    ctx.register_variable("ml_test_data", "tensor", {
        "shape": [test_samples, 4], 
        "data": train_data["X_test"]
    })
    ctx.register_variable("ml_test_labels", "integer_list", train_data["y_test"])
    ctx.set("ml_feature_names", train_data["feature_names"])
    
    return {
        "dataset_name": dataset,
        "total_samples": total_samples,
        "train_samples": train_samples,
        "test_samples": test_samples,
        "feature_names": train_data["feature_names"]
    }
```

**File Changes Required:**
- [`priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py`](../../priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py): Lines 393-552

### Python Code Organization

#### Current Structure
```
priv/python/snakepit_bridge/adapters/showcase/
├── __init__.py
├── showcase_adapter.py  # 564 lines, monolithic
└── tool.py
```

#### Proposed Structure
```
priv/python/snakepit_bridge/adapters/showcase/
├── __init__.py
├── showcase_adapter.py      # Main adapter, delegates to handlers
├── tool.py
├── handlers/
│   ├── __init__.py
│   ├── basic_ops.py        # Basic operations (ping, echo, error_demo)
│   ├── session_ops.py      # Session management operations  
│   ├── binary_ops.py       # Binary serialization demos
│   ├── streaming_ops.py    # Streaming operations
│   ├── concurrent_ops.py   # Concurrent task demonstrations
│   ├── variable_ops.py     # Variable management operations
│   └── ml_workflow.py      # Machine learning workflow operations
└── utils/
    ├── __init__.py
    └── ml_helpers.py       # ML utility functions
```

#### Refactored Main Adapter

**File:** [`priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py`](../../priv/python/snakepit_bridge/adapters/showcase/showcase_adapter.py)

```python
from typing import Dict, Any
from snakepit_bridge import SessionContext
from .handlers import (
    BasicOpsHandler,
    SessionOpsHandler,
    BinaryOpsHandler,
    StreamingOpsHandler,
    ConcurrentOpsHandler,
    VariableOpsHandler,
    MLWorkflowHandler
)

class ShowcaseAdapter:
    """Main adapter demonstrating Snakepit features through specialized handlers."""
    
    def __init__(self):
        # Initialize handlers
        self.handlers = {
            'basic': BasicOpsHandler(),
            'session': SessionOpsHandler(),
            'binary': BinaryOpsHandler(),
            'streaming': StreamingOpsHandler(),
            'concurrent': ConcurrentOpsHandler(),
            'variable': VariableOpsHandler(),
            'ml': MLWorkflowHandler()
        }
        
        # Build tool registry from all handlers
        self.tools = {}
        for handler in self.handlers.values():
            self.tools.update(handler.get_tools())
    
    def set_session_context(self, session_context):
        """Set the session context for this adapter instance."""
        self.session_context = session_context
    
    def execute_tool(self, tool_name: str, arguments: Dict[str, Any], context) -> Any:
        """Execute a tool by name with given arguments."""
        if tool_name in self.tools:
            tool = self.tools[tool_name]
            return tool.func(context, **arguments)
        else:
            raise ValueError(f"Unknown tool: {tool_name}")
```

#### Example Handler Implementation

**File:** [`priv/python/snakepit_bridge/adapters/showcase/handlers/session_ops.py`](../../priv/python/snakepit_bridge/adapters/showcase/handlers/session_ops.py)

```python
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
        # Store all state in SessionContext
        ctx.set("session_start_time", time.time())
        ctx.set("command_count", 0)
        ctx.set("counter", 0)
        
        return {
            "timestamp": datetime.now().isoformat(),
            "worker_pid": os.getpid(),
            "session_id": ctx.session_id
        }
    
    def cleanup_session(self, ctx) -> Dict[str, Any]:
        """Clean up session, demonstrating state retrieval."""
        start_time = ctx.get("session_start_time", time.time())
        duration_ms = (time.time() - start_time) * 1000
        command_count = ctx.get("command_count", 0)
        
        # Note: Actual cleanup happens in Elixir when session ends
        return {
            "duration_ms": round(duration_ms, 2),
            "command_count": command_count
        }
    
    def increment_counter(self, ctx) -> Dict[str, Any]:
        """Demonstrate atomic counter increment via SessionContext."""
        # Get current values
        counter = ctx.get("counter", 0)
        command_count = ctx.get("command_count", 0)
        
        # Increment
        new_counter = counter + 1
        new_command_count = command_count + 1
        
        # Store back
        ctx.set("counter", new_counter)
        ctx.set("command_count", new_command_count)
        
        return {"value": new_counter}
```

### Error Handling Patterns

#### Current Issues

Most demos use optimistic error handling:
```elixir
{:ok, result} = Snakepit.execute_in_session(session_id, "some_command", %{})
```

This pattern will crash if the Python worker returns an error.

#### Proposed Error Handling

**File:** [`lib/snakepit_showcase/demos/ml_workflow_demo.ex`](../lib/snakepit_showcase/demos/ml_workflow_demo.ex)

```elixir
defmodule SnakepitShowcase.Demos.MLWorkflowDemo do
  @moduledoc """
  Demonstrates ML workflow with proper error handling.
  """
  
  def run do
    IO.puts("\n🤖 Machine Learning Workflow Demo\n")
    
    with {:ok, session_id} <- Snakepit.SessionManager.create_session(),
         :ok <- load_and_preprocess_data(session_id),
         :ok <- train_model_with_progress(session_id),
         :ok <- evaluate_model(session_id) do
      IO.puts("✅ ML workflow completed successfully")
      Snakepit.SessionManager.cleanup_session(session_id)
    else
      {:error, reason} ->
        IO.puts("❌ ML workflow failed: #{inspect(reason)}")
        handle_ml_error(reason)
    end
  end
  
  defp load_and_preprocess_data(session_id) do
    IO.puts("1️⃣ Loading and Preprocessing Data")
    
    case Snakepit.execute_in_session(session_id, "load_sample_data", %{
      dataset: "iris",
      split: 0.8
    }) do
      {:ok, result} ->
        IO.puts("   Loaded #{result["total_samples"]} samples")
        preprocess_data(session_id)
        
      {:error, %{error_type: "DataNotFoundError"} = error} ->
        IO.puts("   ⚠️  Dataset not found, using synthetic data")
        generate_synthetic_data(session_id)
        
      {:error, reason} ->
        {:error, {:data_loading_failed, reason}}
    end
  end
  
  defp train_model_with_progress(session_id) do
    IO.puts("\n2️⃣ Training Model")
    
    # Set up timeout for long-running training
    timeout = 300_000  # 5 minutes
    
    # Use streaming with error handling
    result = Snakepit.execute_stream_in_session(
      session_id,
      "train_model",
      %{algorithm: "random_forest", max_depth: 10},
      fn
        {:error, reason} ->
          IO.puts("   ❌ Training error: #{inspect(reason)}")
          {:halt, {:error, reason}}
          
        %{"type" => "progress"} = update ->
          IO.puts("   Epoch #{update["epoch"]}/#{update["total_epochs"]}: " <>
                 "accuracy = #{Float.round(update["accuracy"], 3)}")
          :ok
          
        %{"type" => "completed"} = result ->
          IO.puts("   ✅ Training completed: accuracy = #{result["final_accuracy"]}")
          :ok
      end,
      timeout: timeout
    )
    
    case result do
      :ok -> :ok
      {:error, :timeout} -> 
        IO.puts("   ⚠️  Training timeout, using partial model")
        :ok  # Continue with partial model
      {:error, reason} -> 
        {:error, {:training_failed, reason}}
    end
  end
  
  defp handle_ml_error({:data_loading_failed, _reason}) do
    IO.puts("""
    
    💡 Tip: Ensure your Python environment has the required packages:
       - numpy
       - sklearn (if using real datasets)
    """)
  end
  
  defp handle_ml_error({:training_failed, _reason}) do
    IO.puts("""
    
    💡 Tip: Training failures can occur due to:
       - Insufficient memory
       - Incompatible hyperparameters
       - Numerical instabilities
    """)
  end
  
  defp handle_ml_error(_) do
    IO.puts("\n💡 Tip: Check the logs for more details")
  end
end
```

### API Usage Documentation

#### When to Use Each Execution Mode

**File:** [`lib/snakepit_showcase/demos/execution_modes_demo.ex`](../lib/snakepit_showcase/demos/execution_modes_demo.ex) (new file)

```elixir
defmodule SnakepitShowcase.Demos.ExecutionModesDemo do
  @moduledoc """
  Demonstrates when to use different Snakepit execution modes.
  """
  
  def run do
    IO.puts("\n🎯 Execution Modes Demo\n")
    
    demonstrate_stateless_execution()
    demonstrate_session_execution()
    demonstrate_streaming_execution()
    demonstrate_execution_tradeoffs()
  end
  
  defp demonstrate_stateless_execution do
    IO.puts("1️⃣ Stateless Execution (Snakepit.execute/3)")
    IO.puts("   Use for: Idempotent, stateless operations")
    IO.puts("   Examples: Data transformations, calculations, one-off tasks\n")
    
    # Example: Simple calculation
    {:ok, result} = Snakepit.execute("echo", %{
      message: "Stateless operations can run on any available worker"
    })
    IO.puts("   Result: #{inspect(result)}")
    
    # Example: Parallel stateless operations
    tasks = for i <- 1..5 do
      Task.async(fn ->
        Snakepit.execute("compute", %{expression: "#{i} ** 2"})
      end)
    end
    
    results = Task.await_many(tasks)
    IO.puts("   Parallel results: #{inspect(results)}")
  end
  
  defp demonstrate_session_execution do
    IO.puts("\n2️⃣ Session-based Execution (Snakepit.execute_in_session/4)")
    IO.puts("   Use for: Stateful workflows, ML pipelines, multi-step processes")
    IO.puts("   Benefits: Worker affinity, state preservation, better performance\n")
    
    {:ok, session_id} = Snakepit.SessionManager.create_session()
    
    # Build up state across multiple calls
    {:ok, _} = Snakepit.execute_in_session(session_id, "init_session", %{})
    
    for i <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(session_id, "increment_counter", %{})
      IO.puts("   Counter after increment #{i}: #{result["value"]}")
    end
    
    # State persists across calls in the same session
    {:ok, result} = Snakepit.execute_in_session(session_id, "get_counter", %{})
    IO.puts("   Final counter value: #{result["value"]}")
    
    Snakepit.SessionManager.cleanup_session(session_id)
  end
  
  defp demonstrate_execution_tradeoffs do
    IO.puts("\n4️⃣ Execution Mode Trade-offs")
    IO.puts("""
    
    Stateless (execute/3):
    ✅ Maximum concurrency - any worker can handle the request
    ✅ Better fault tolerance - worker crashes don't lose state
    ✅ Simpler to reason about
    ❌ No state preservation between calls
    ❌ Can't build up complex in-memory structures
    
    Session-based (execute_in_session/4):
    ✅ State preservation across calls
    ✅ Worker affinity for better cache usage
    ✅ Can maintain expensive objects (ML models, connections)
    ❌ Limited to one worker per session
    ❌ State lost if worker crashes
    
    Streaming:
    ✅ Progressive results for long operations
    ✅ Memory efficient for large datasets
    ✅ Better user experience with progress updates
    ❌ More complex error handling
    ❌ Can't easily retry failed chunks
    """)
  end
end
```

## Implementation Plan

### Phase 1: State Management Refactoring (Priority: High)
1. Update `showcase_adapter.py` to remove all class-level state variables
2. Refactor all state operations to use SessionContext
3. Update Elixir demos to show state being properly managed
4. Add tests to verify no Python state leakage

### Phase 2: Code Organization (Priority: Medium)
1. Create handler subdirectory structure
2. Split monolithic adapter into domain-specific handlers
3. Update imports and tool registration
4. Ensure all demos still work with new structure

### Phase 3: Error Handling (Priority: High)
1. Update MLWorkflowDemo with comprehensive error handling
2. Add error handling to ConcurrentDemo
3. Create error handling guide in documentation
4. Add test cases for error scenarios

### Phase 4: Documentation and Examples (Priority: Medium)
1. Create ExecutionModesDemo
2. Update README with best practices section
3. Add inline documentation explaining trade-offs
4. Create migration guide for existing users

## Testing Strategy

### Unit Tests
- Test each handler in isolation
- Verify SessionContext is used exclusively for state
- Test error propagation from Python to Elixir

### Integration Tests
- Run all demos with refactored code
- Verify state consistency across worker restarts
- Test concurrent access to shared state

### Performance Tests
- Benchmark SessionContext operations vs local state
- Measure overhead of proper state management
- Ensure refactoring doesn't degrade performance

## Migration Notes

### Breaking Changes
1. Python adapter state will no longer persist in class variables
2. Any code depending on direct state access will need updates
3. Handler structure changes may affect custom extensions

### Compatibility
- Maintain backward compatibility where possible
- Provide migration utilities for existing state
- Document all breaking changes clearly

## Conclusion

These improvements will transform the showcase from a feature demonstration into a production-ready reference implementation. By enforcing proper state management through SessionContext, organizing code into logical handlers, demonstrating robust error handling, and clearly documenting API usage patterns, developers will have a comprehensive guide for building scalable, maintainable applications with Snakepit.