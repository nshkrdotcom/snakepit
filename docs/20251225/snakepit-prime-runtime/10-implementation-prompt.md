# 10 - Implementation Prompt (Snakepit Prime Runtime)

You are implementing the Snakepit Prime Runtime changes in this repo.
Work from: `/home/home/p/g/n/snakepit`.

## Goal

Ship Snakepit 0.7.(x+1) runtime upgrades that enable:

- Zero-copy interop (DLPack + Arrow)
- Crash barrier with tainting + retry policy
- Hermetic Python runtime (uv-managed)
- Structured exception translation
- A stable runtime contract for SnakeBridge wrappers
- Telemetry additions for the above

All tests must pass, with no warnings, no errors, no Dialyzer issues, and no Credo issues.

## Required Reading (Docs)

Read these first:

- `docs/20251225/snakepit-prime-runtime/README.md`
- `docs/20251225/snakepit-prime-runtime/00-overview.md`
- `docs/20251225/snakepit-prime-runtime/01-zero-copy.md`
- `docs/20251225/snakepit-prime-runtime/02-crash-barrier.md`
- `docs/20251225/snakepit-prime-runtime/03-hermetic-python.md`
- `docs/20251225/snakepit-prime-runtime/04-exception-translation.md`
- `docs/20251225/snakepit-prime-runtime/05-runtime-contract-snakebridge.md`
- `docs/20251225/snakepit-prime-runtime/06-telemetry-observability.md`
- `docs/20251225/snakepit-prime-runtime/07-testing-tdd-plan.md`
- `docs/20251225/snakepit-prime-runtime/08-migration-notes.md`
- `docs/20251225/snakepit-prime-runtime/09-config-reference.md`

Read the current Snakepit docs and runtime docs:

- `README.md`
- `ARCHITECTURE.md`
- `README_GRPC.md`
- `README_PROCESS_MANAGEMENT.md`
- `README_TESTING.md`
- `TELEMETRY.md`
- `LOG_LEVEL_CONFIGURATION.md`
- `README_BIDIRECTIONAL_TOOL_BRIDGE.md`

Read the runtime contract in SnakeBridge for alignment:

- `/home/home/p/g/n/snakebridge/docs/20251225/snakebridge-v3-canonical/14-runtime-integration.md`
- `/home/home/p/g/n/snakebridge/docs/20251225/snakebridge-v3-canonical/17-ml-pillars.md`

## Required Reading (Source)

Start here:

- `lib/snakepit/application.ex`
- `lib/snakepit/pool/`
- `lib/snakepit/worker/`
- `lib/snakepit/adapters/`
- `lib/snakepit/telemetry/`
- `priv/python/` (grpc servers and adapter protocol)

## Constraints

- Do not change the SnakeBridge compile-time architecture (prepass only).
- Keep Snakepit as the runtime substrate; SnakeBridge remains codegen only.
- Preserve existing public APIs unless explicitly superseded.
- No mid-compilation injection or BEAM caching changes.
- All changes must be deterministic and content-stable.

## Implementation Requirements

### 1) Zero-Copy Interop

- Add `Snakepit.ZeroCopy` and `Snakepit.ZeroCopyRef`.
- Implement DLPack and Arrow import/export paths.
- Provide explicit `close/1` to release handles.
- Fallback to copy with a logged warning when zero-copy is unavailable.
- Emit telemetry events described in `06-telemetry-observability.md`.

### 2) Crash Barrier

- Implement worker tainting and retry policy on crash.
- Respect `idempotent` flag from the call payload.
- Expose config in `config :snakepit, :crash_barrier`.
- Emit crash barrier telemetry events.

### 3) Hermetic Python Runtime

- Add uv-managed Python install option (`config :snakepit, :python`).
- Integrate with `mix snakepit.setup` and `mix snakepit.doctor`.
- Record runtime identity in the environment metadata used by SnakeBridge.
- Emit clear errors when uv is missing or install fails.

### 4) Exception Translation

- Standardize Python adapter error payloads.
- Map Python exceptions to Elixir structs in `Snakepit.Error.*`.
- Preserve traceback and callsite metadata.
- Ensure errors remain pattern-matchable in Elixir.

### 5) Runtime Contract (SnakeBridge -> Snakepit)

- Accept `kwargs` and `call_type` for function/class/method/attr calls.
- Accept `idempotent` for crash barrier retries.
- Support `snakebridge.call` and `snakebridge.stream`.
- Maintain a payload version field if schema changes.

### 6) Telemetry and Observability

- Add events for zero-copy, crash barrier, and exception translation.
- Document new events in `TELEMETRY.md`.

### 7) Documentation and Examples

- Update ALL docs to reflect new runtime behavior.
- Update `README.md`, `ARCHITECTURE.md`, `README_GRPC.md`,
  `README_PROCESS_MANAGEMENT.md`, and `README_TESTING.md`.
- Update examples under `examples/` and any guides that reference runtime calls.

### 8) Tests (TDD)

Follow TDD: write tests first, then implement.

Minimum test coverage:

- Zero-copy handle lifecycle (unit tests)
- Crash barrier retry + taint (unit tests)
- Hermetic runtime selection (unit tests)
- Exception translation mapping (unit tests)
- Runtime contract acceptance for kwargs/call_type (integration tests)

Use `SNAKEPIT_GPU_TESTS=true` gating for optional GPU coverage.

## Quality Gate

All of these must pass with no warnings:

- `mix test`
- `mix test --include integration` (if integration suite exists)
- `mix dialyzer`
- `mix credo --strict`
- `mix format --check-formatted`

## Version and Changelog

- Bump Snakepit version to 0.7.(x+1) in `mix.exs`.
- Update dependency snippet in `README.md`.
- Add a `2025-12-25` entry to `CHANGELOG.md` with all runtime changes.

## Output Expectations

Deliver clean commits with:

- Implementation complete
- Tests passing
- Docs and examples updated
- Version bumped
- Changelog updated

