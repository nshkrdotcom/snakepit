# Agent Prompt: Snakepit Runtime Hygiene

## Mission

Implement the runtime hygiene plan in `design.md` for Snakepit. Focus on
shutdown cleanup determinism, process-group termination, and quiet-by-default
logging for library consumers.

## Required Reading (Full Paths)

- /home/home/p/g/n/snakepit/docs/20251226/runtime-hygiene/design.md

Core source to inspect and modify:

- /home/home/p/g/n/snakepit/lib/snakepit/application.ex
- /home/home/p/g/n/snakepit/lib/snakepit/grpc_worker.ex
- /home/home/p/g/n/snakepit/lib/snakepit/pool/application_cleanup.ex
- /home/home/p/g/n/snakepit/lib/snakepit/pool/process_registry.ex
- /home/home/p/g/n/snakepit/lib/snakepit/pool/worker_supervisor.ex
- /home/home/p/g/n/snakepit/lib/snakepit/process_killer.ex
- /home/home/p/g/n/snakepit/lib/snakepit/logger.ex

Test patterns to follow:

- /home/home/p/g/n/snakepit/test

## Implementation Rules

- Use TDD: write failing tests first, implement minimal code to pass, refactor.
- Do not add new behavior without test coverage.
- Prefer additive changes and feature flags where risk is higher (process group kill).
- Keep cleanup logic scoped to the current run_id; never kill unrelated processes.
- Default logs must be quiet for library usage, but errors must still surface.

## Quality Gates

- All tests must pass.
- No warnings or runtime errors.
- Format checks must pass (`mix format --check-formatted`).

## Deliverables

- Implement cleanup barrier on shutdown.
- Process group termination support with safe fallback.
- Emergency cleanup available even when pooling is disabled.
- Manual cleanup API (`Snakepit.cleanup/0`).
- Logging defaults and gating per design.
- Tests covering shutdown cleanup, process group kill, and logging defaults.
