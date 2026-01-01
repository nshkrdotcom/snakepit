# Prompt 01: Exit Semantics and IO-Safe Halt

Required reading (docs/src):
- docs/20260101/0.9.0-release-hardening/docs/src/01-research-foundations.md
- docs/20260101/0.9.0-release-hardening/docs/src/02-research-current-state.md
- docs/20260101/0.9.0-release-hardening/docs/src/03-planning-design.md
- docs/20260101/0.9.0-release-hardening/docs/src/04-planning-test-strategy.md
- docs/20260101/0.9.0-release-hardening/docs/src/05-planning-docs-changelog.md

Context
- Snakepit.run_as_script/2 currently supports a boolean :halt option and an
  env var SNAKEPIT_SCRIPT_HALT. This is insufficiently expressive and the
  exit path can be unsafe when stdout/stderr are closed or piped.
- We need explicit exit semantics and an IO-safe hard exit path.

Goal
- Introduce exit_mode with clear, documented behavior, preserve compatibility
  with :halt, and ensure the exit path performs no IO that could block.

Tasks (TDD required)
1) Add tests first.
   - Unit tests for exit mode selection and precedence:
     - :exit_mode overrides :halt.
     - :halt true maps to :exit_mode :halt when :exit_mode is unset.
     - SNAKEPIT_SCRIPT_EXIT parsing (none|halt|stop|auto).
   - Integration tests (external VM):
     - exit_mode :halt exits with status 0/1.
     - broken pipe simulation (pipe to head -1) does not hang.
     - timeout wrapper does not hang (timeout --foreground).

2) Implement exit_mode support.
   - Add :exit_mode option to run_as_script/2.
   - Preserve :halt compatibility.
   - Add env var SNAKEPIT_SCRIPT_EXIT (string) and map it to exit_mode.
   - Remove all direct IO in the exit path (no :io.put_chars or :io.format).
   - Ensure exit_mode is logged only before shutdown (Logger-based).

3) Ensure the exit path uses safe semantics.
   - :halt -> System.halt/1 (or equivalent) without IO.
   - :stop -> System.stop/1 and block the caller until VM shutdown.
   - :none -> return normally.

4) Update docs.
   - Update README.md, guides/getting-started.md, guides/production.md,
     docs/20251229/documentation-overhaul/01-core-api.md.
   - Document exit_mode, env vars, and broken pipe behavior.

5) Append changes to CHANGELOG.md under a new 0.9.0 entry.

Constraints
- Use TDD: tests first, then implementation.
- Keep behavior backward compatible unless documented as changed.
- Update README and all guides as described in docs/src/05-planning-docs-changelog.md.

