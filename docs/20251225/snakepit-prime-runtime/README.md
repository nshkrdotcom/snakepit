# Snakepit Prime Runtime (2025-12-25)

**Status**: Design + implementation guide for runtime enhancements
**Scope**: Snakepit runtime only (no SnakeBridge codegen changes)

This document set defines the **must-have runtime changes** that make Snakepit a world-class substrate for ML workloads while preserving the existing two-layer architecture:

- Snakepit = runtime (pooling, workers, execution, sessions)
- SnakeBridge = compile-time codegen (scanner, introspector, generator)

## Why This Set Exists

SnakeBridge v3 is already strong on determinism and tooling. The missing credibility signals are in runtime behavior: **zero-copy interop**, **crash isolation**, **structured errors**, and **hermetic Python**. These are runtime responsibilities, so they live in Snakepit.

## Must-Have Pillars

1. **Zero-copy data interop** (DLPack + Arrow)
2. **Crash barrier** with tainting and optional retry
3. **Structured exception translation** (pattern-matchable errors)
4. **Hermetic Python runtime** (uv-managed interpreter + hash in lockfile)

## Doc Set Map

- `00-overview.md` - high-level runtime changes and priorities
- `01-zero-copy.md` - DLPack/Arrow architecture, handles, ownership rules
- `02-crash-barrier.md` - tainting, retry policy, exit-code classification
- `03-hermetic-python.md` - uv-managed interpreter, runtime identity, CI
- `04-exception-translation.md` - structured error mapping
- `05-runtime-contract-snakebridge.md` - `snakebridge.call` payload contract
- `06-telemetry-observability.md` - new events and metrics
- `07-testing-tdd-plan.md` - TDD plan, unit/integration strategy
- `08-migration-notes.md` - upgrade and behavior changes
- `09-config-reference.md` - consolidated config additions
- `10-implementation-prompt.md` - build instructions for an implementing agent

## Non-Goals

- No changes to SnakeBridge architecture or generation flow
- No mid-compilation injection or runtime codegen
- No BEAM caching or auto-pruning

