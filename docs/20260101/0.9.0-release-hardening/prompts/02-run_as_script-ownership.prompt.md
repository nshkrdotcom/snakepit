# Prompt 02: Ownership-Aware Start/Stop in run_as_script

Required reading (docs/src):
- docs/20260101/0.9.0-release-hardening/docs/src/01-research-foundations.md
- docs/20260101/0.9.0-release-hardening/docs/src/02-research-current-state.md
- docs/20260101/0.9.0-release-hardening/docs/src/03-planning-design.md
- docs/20260101/0.9.0-release-hardening/docs/src/04-planning-test-strategy.md
- docs/20260101/0.9.0-release-hardening/docs/src/05-planning-docs-changelog.md

Context
- run_as_script/2 currently calls Application.stop(:snakepit) unconditionally.
- This can shut down Snakepit when used inside a host application, which
  violates ownership boundaries.

Goal
- Only stop Snakepit if this call started it, unless explicitly overridden.

Tasks (TDD required)
1) Add tests first.
   - Unit tests for ownership tracking logic.
   - A test that starts Snakepit, calls run_as_script with stop_mode :if_started,
     and verifies Snakepit remains running.
   - A test that calls run_as_script when Snakepit is not started and verifies
     it stops (and cleans up) at the end.

2) Implement stop_mode.
   - Add :stop_mode option with :if_started (default), :always, :never.
   - Track which applications were started by Application.ensure_all_started/1.
   - Only call Application.stop(:snakepit) when stop_mode permits it.

3) Update examples bootstrap defaults.
   - Ensure Snakepit.Examples.Bootstrap.run_example/2 aligns with the new
     stop_mode behavior and remains safe for wrapper scripts.

4) Update API docs (single source of truth).
   - Update `docs/20251229/documentation-overhaul/01-core-api.md`:
     - Document `stop_mode` (`:if_started` default, `:always`, `:never`) and
       how ownership is detected.
     - Add/update the authoritative `stop_mode x exit_mode` matrix (embedded
       vs standalone) and explicitly warn against embedded + `:stop`/`:halt`.
   - Do not update README/guides/examples in this prompt (handled in Prompt 04).

5) Append changes to `CHANGELOG.md` under the existing `## 0.9.0 - Unreleased`
   section (Added/Changed/Fixed only). Do not create a new 0.9.0 section.

Constraints
- Use TDD: tests first, then implementation.
- Keep existing behavior by default wherever possible.
- Follow the documentation policy in docs/src/05-planning-docs-changelog.md.
