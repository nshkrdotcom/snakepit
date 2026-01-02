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
   - Unit tests for exit mode selection and precedence (pure functions):
     - :exit_mode overrides legacy :halt.
     - legacy :halt true maps to exit_mode: :halt when :exit_mode is unset.
     - Full precedence chain: :exit_mode > legacy :halt > SNAKEPIT_SCRIPT_EXIT >
       legacy SNAKEPIT_SCRIPT_HALT > default.
     - SNAKEPIT_SCRIPT_EXIT parsing: trim + case-insensitive; empty => unset;
       invalid => ignored (and produces a pre-shutdown Logger warning).
   - Integration tests (external VM):
     - exit_mode :halt exits with status 0 on normal return, status 1 on
       exception (Status Code Rules).
     - exit_mode :stop requests VM shutdown with status 0/1 per Status Code
       Rules (and blocks until exit).
     - Broken pipe simulation must be portable (prefer pure Elixir
       pipe-close harness; do not require GNU `timeout` flags).

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

4) Update API docs (single source of truth).
   - Update `docs/20251229/documentation-overhaul/01-core-api.md` to add
     "Script Lifecycle (0.9.0)" including:
     - Exit Selection Precedence table
     - `SNAKEPIT_SCRIPT_EXIT` parsing rules
     - Legacy `SNAKEPIT_SCRIPT_HALT` compatibility + deprecation note
     - Status Code Rules
   - Do not update README/guides/examples in this prompt (handled in Prompt 04).

5) Append changes to `CHANGELOG.md` under `## 0.9.0 - Unreleased`.
   - Create the `0.9.0 - Unreleased` section only if missing, with subheadings
     `### Added`, `### Changed`, `### Fixed`.
   - Otherwise append under existing subheadings only (no duplicate 0.9.0
     headings).

Constraints
- Use TDD: tests first, then implementation.
- Keep behavior backward compatible unless documented as changed.
- Follow the documentation policy in docs/src/05-planning-docs-changelog.md.
