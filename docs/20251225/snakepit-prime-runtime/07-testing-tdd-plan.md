# 07 - Testing and TDD Plan

## Philosophy

All changes must be built with TDD. Tests should fail first, then implementation follows.

## Test Layers

### Unit Tests

- Zero-copy handle creation and cleanup
- Crash barrier classification logic
- Exception mapping functions
- Runtime selection (managed Python vs system)

### Integration Tests

- Python adapter returns structured exceptions
- Zero-copy round-trip with NumPy (CPU)
- Crash barrier handles simulated worker crash

### Optional GPU Tests

- DLPack CUDA handle round-trip
- Crash barrier on CUDA fatal error

Run GPU tests only when `SNAKEPIT_GPU_TESTS=true`.

## Suggested Test Files

- `test/snakepit/zero_copy_test.exs`
- `test/snakepit/crash_barrier_test.exs`
- `test/snakepit/exception_translation_test.exs`
- `test/snakepit/python_runtime_test.exs`
- `test/integration/zero_copy_numpy_test.exs`

## TDD Flow

1. Write failing test
2. Implement minimal logic
3. Make test pass
4. Refactor
5. Repeat

## CI Expectations

- All unit tests pass
- Integration tests pass when Python is available
- No warnings, no credo issues, no dialyzer issues

