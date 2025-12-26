# 08 - Migration Notes (Snakepit 0.7.x -> 0.7.(x+1))

## Scope

This document covers the runtime changes introduced by Snakepit Prime in the 0.7.(x+1) line. The goal is to keep existing pools and adapters working while adding zero-copy, crash barrier, hermetic Python, and structured error translation.

## Summary of Changes

- Structured exception translation replaces some string errors with typed structs.
- Crash barrier adds worker tainting and retry policy for unstable Python calls.
- Zero-copy interop adds DLPack and Arrow handles for large data.
- Hermetic Python runtime adds optional uv-managed Python installs.
- SnakeBridge runtime payload is normalized (kwargs, call_type, idempotent flag).

## Behavior Changes

- Errors that previously returned `{:error, message}` may now return:
  `{:error, %Snakepit.Error.PythonException{...}}`.
- Worker crashes may trigger transparent retries for idempotent calls.
- When zero-copy is enabled, large tensor and table arguments may no longer be serialized.

## Upgrade Steps

1. Update dependency in `mix.exs` to the new 0.7.(x+1) version.
2. Run `mix deps.get` and `mix snakepit.setup` to refresh Python assets.
3. Review config changes in `09-config-reference.md` and update `config/*.exs`.
4. If you use SnakeBridge, ensure generated wrappers emit:
   - `kwargs` (even if empty)
   - `call_type` for class/method/attr calls
   - `idempotent` flag for crash barrier retries
5. Run test suite and verify no warnings.

## Compatibility Notes

- Zero-copy is opt-in. If disabled, serialization remains unchanged.
- Hermetic Python is opt-in. If disabled, system Python is used as before.
- Crash barrier is configurable per pool; it can be disabled if you want
  strict "no retries" behavior.

## Rollback Guidance

If you need to revert:

- Disable new features in config (`zero_copy`, `crash_barrier`, `python.managed`).
- Revert dependency version in `mix.exs`.
- Regenerate Python assets with `mix snakepit.setup`.

