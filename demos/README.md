# Snakepit Demos

This directory contains demonstration scripts showcasing Snakepit's core functionality.

## ⚠️ Important Note

Due to recent project reorganization, the demos are currently **not runnable** as described in their file comments. The main `mix.exs` was moved to the `demos/` directory, breaking the expected project structure. To run these demos, the project structure needs to be restored with a proper `mix.exs` in the root directory.

## Available Demos

### 1. **core_functionality_demo.exs**
- **Purpose**: Demonstrates essential Snakepit session/pooler features
- **Features Covered**:
  - Direct worker usage (GenericWorker functionality)
  - Pool-based execution
  - Session affinity management
  - Session helper utilities
  - Pool statistics tracking
- **Expected Run Command**: `MIX_ENV=test mix run core_functionality_demo.exs`

### 2. **session_pooler_demo.exs**
- **Purpose**: Comprehensive demonstration of Snakepit core functionality in both pooled and non-pooled modes
- **Features Covered**:
  - Application startup validation
  - Direct GenericWorker testing
  - Session affinity adapter testing
  - Pool-enabled execution
  - Session helpers
  - Error handling
- **Expected Run Command**: `MIX_ENV=test mix run session_pooler_demo.exs`

### 3. **fresh_pool_demo.exs**
- **Purpose**: Ensures pool starts properly with proper configuration
- **Features Covered**:
  - Clean application startup with pool configuration
  - Pool initialization verification
  - Basic pool execution
  - Session affinity with fresh pool
  - Pool statistics
- **Expected Run Command**: `MIX_ENV=test elixir -S mix run fresh_pool_demo.exs`

### 4. **working_pool_demo.exs**
- **Purpose**: Demonstrates Snakepit with actual pool functionality
- **Features Covered**:
  - Pool configuration and startup
  - Basic pool execution
  - Session affinity demonstration
  - Pool statistics
  - Enhanced session helpers
  - Error handling and recovery
- **Expected Run Command**: `MIX_ENV=test elixir -S mix run working_pool_demo.exs`

### 5. **simple_test.exs**
- **Purpose**: Basic validation of available modules and configuration
- **Features Covered**:
  - Application startup check
  - Core module availability verification
  - Test adapter validation
  - Pool status check
  - Configuration inspection
- **Expected Run Command**: `MIX_ENV=test mix run simple_test.exs`

### 6. **test_examples.exs**
- **Purpose**: Validates core Snakepit functionality with comprehensive checks
- **Features Covered**:
  - Application startup validation
  - Pool availability testing
  - Mock adapter validation
  - Standalone GenericWorker operation
  - Pool execution (when available)
  - Session helper availability
- **Expected Run Command**: `mix run test_examples.exs`

### 7. **standalone_pool_demo.exs**
- **Purpose**: Shows how to use Snakepit in a completely fresh session
- **Features Covered**:
  - Fresh application start with Mix.install
  - Pool configuration before module loading
  - Full pool functionality demonstration
- **Expected Run Command**: `elixir standalone_pool_demo.exs`

### 8. **mock_vs_real_demo.exs**
- **Purpose**: Clarifies what's actually real vs mocked in the test infrastructure
- **Key Insights**:
  - Infrastructure (GenServers, pools, sessions) is REAL
  - Adapter (external process calls) is MOCKED
  - Real OTP supervision trees and process lifecycle
  - Fake responses from mock adapters

### 9. **real_vs_mock_check.exs**
- **Purpose**: Detailed infrastructure analysis showing real vs mocked components
- **Features Covered**:
  - Real pool process verification
  - Real worker process inspection
  - Session affinity validation
  - Statistics tracking verification
- **Expected Run Command**: `MIX_ENV=test elixir -S mix run real_vs_mock_check.exs`

### 10. **test_bidirectional.py** ❌
- **Purpose**: Quick test of bidirectional tool calling
- **Status**: **Not working** - Requires gRPC bridge setup and Python dependencies
- **Issues**:
  - Depends on gRPC server running on localhost:50051
  - Requires Python bridge modules installed
  - Part of the gRPC/Python integration, not core Elixir demos

## Demo Categories

### ✅ Core Functionality Demos
- `core_functionality_demo.exs`
- `session_pooler_demo.exs`
- `simple_test.exs`
- `test_examples.exs`

### ✅ Pool Management Demos
- `fresh_pool_demo.exs`
- `working_pool_demo.exs`
- `standalone_pool_demo.exs`

### ✅ Infrastructure Analysis
- `mock_vs_real_demo.exs`
- `real_vs_mock_check.exs`

### ❌ External Integration (Not Working)
- `test_bidirectional.py` - Requires gRPC bridge setup

## Key Concepts Demonstrated

1. **GenericWorker**: The core worker process that handles external language integration
2. **Pool Management**: Dynamic supervision and worker pool management
3. **Session Affinity**: Routing requests to the same worker for stateful operations
4. **Mock Adapters**: Testing infrastructure without external dependencies
5. **Configuration**: How to properly configure Snakepit for different modes

## Running the Demos

To run these demos properly, the project needs to be restructured:

1. Restore the main `mix.exs` to the root directory
2. Ensure all dependencies are available: `mix deps.get`
3. Run demos with appropriate environment: `MIX_ENV=test mix run demos/<demo_name>.exs`

Alternatively, use the `standalone_pool_demo.exs` which includes its own Mix.install setup.

## Notes

- All Elixir demos use mock adapters to demonstrate functionality without external dependencies
- The infrastructure (pools, sessions, workers) is real - only the external calls are mocked
- The Python demo (`test_bidirectional.py`) requires additional setup and is not part of the core demo suite