# Snakepit Testing Guide

This guide covers the testing approach for the Snakepit project, including test organization, running tests, and understanding test output.

## Test Overview

Snakepit contains comprehensive test coverage for:
- Protocol foundation (gRPC infrastructure)
- Core variable system with SessionStore
- Type system and serialization
- Bridge server implementation
- Python integration

## Running Tests

### Basic Test Execution
```bash
# Run all tests
mix test

# Run tests with specific tags
mix test --exclude performance  # Default: excludes performance tests
mix test --only performance      # Run only performance tests

# Run specific test files
mix test test/snakepit/bridge/session_store_test.exs
```

### Test Modes

The test suite runs in different modes based on tags:
- **Default**: Unit and integration tests (excludes `:performance` tag)
- **Performance**: Benchmarks and latency tests (use `--only performance`)

## Understanding Test Output

### Expected Warnings

Some tests intentionally trigger warnings to verify error handling. These are **expected and normal**:

1. **gRPC Server Shutdown Warning**
   ```
   ⏰ gRPC server PID XXXXX did not exit gracefully within 500ms. Forcing SIGKILL.
   ```
   This occurs during test cleanup when the gRPC server is forcefully terminated. It's expected behavior.

2. **Server Configuration**
   All gRPC server configuration warnings have been resolved in the current implementation.

### Test Statistics

A typical successful test run shows:
```
Finished in 1.9 seconds (1.1s async, 0.7s sync)
182 tests, 0 failures
```

## Test Organization

```
test/
├── snakepit/
│   ├── bridge/
│   │   ├── session_store_test.exs      # Core state management
│   │   ├── serialization_test.exs      # Type serialization
│   │   └── variables/
│   │       └── types_test.exs          # Type system tests
│   ├── grpc/
│   │   ├── bridge_server_test.exs      # gRPC server implementation
│   │   └── client_test.exs             # gRPC client tests
│   └── integration/
│       └── bridge_integration_test.exs  # Full stack integration
└── test_helper.exs                      # Test configuration
```

## Key Test Categories

### 1. Protocol Tests
Tests the gRPC protocol implementation including:
- Service definitions
- Message serialization
- RPC handlers

### 2. Type System Tests
Validates the type system including:
- Type validation and constraints
- Serialization/deserialization
- Special value handling (infinity, NaN)

### 3. SessionStore Tests
Tests the core state management:
- Session lifecycle
- Variable CRUD operations
- Batch operations
- TTL and cleanup

### 4. Integration Tests
End-to-end tests covering:
- Python-Elixir communication
- Full request/response cycles
- Error propagation

## Writing Tests

### Test Patterns

1. **Use descriptive test names**
   ```elixir
   test "handles special float values correctly" do
     # Test implementation
   end
   ```

2. **Group related tests with describe blocks**
   ```elixir
   describe "batch operations" do
     test "get_variables returns all found variables" do
       # Test implementation
     end
   end
   ```

3. **Capture expected logs**
   ```elixir
   {result, logs} = with_log(fn ->
     # Code that generates expected warnings
   end)
   assert logs =~ "Expected warning message"
   ```

### Performance Tests

Performance tests are tagged and excluded by default:
```elixir
@tag :performance
test "handles 1000 concurrent requests" do
  # Performance test implementation
end
```

## Continuous Integration

The test suite is designed to run in CI environments:
- All tests must pass before merging
- Performance tests are run separately
- Test coverage is monitored

## Troubleshooting

### Common Issues

1. **Port Already in Use**
   - The gRPC server uses port 50051
   - Ensure no other services are using this port

2. **Python Dependencies**
   - Some integration tests require Python dependencies
   - Run `pip install -r priv/python/requirements.txt`

3. **Compilation Warnings**
   - Protocol buffer regeneration may be needed
   - Run `mix grpc.gen` to regenerate Elixir bindings

## Related Documentation

- [Main README](README.md) - Project overview
- [gRPC Integration Plan](docs/GRPC_INTEGRATION_PLAN.md) - Protocol details
- [Stage 0 Completion Report](docs/stage0_completion_report.md) - Implementation status