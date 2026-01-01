# Prompt 03: Shutdown and Cleanup Hardening

Required reading (docs/src):
- docs/20260101/0.9.0-release-hardening/docs/src/01-research-foundations.md
- docs/20260101/0.9.0-release-hardening/docs/src/02-research-current-state.md
- docs/20260101/0.9.0-release-hardening/docs/src/03-planning-design.md
- docs/20260101/0.9.0-release-hardening/docs/src/04-planning-test-strategy.md
- docs/20260101/0.9.0-release-hardening/docs/src/05-planning-docs-changelog.md

Context
- Shutdown and cleanup logic is split between run_as_script, Application.stop,
  RuntimeCleanup, and ApplicationCleanup. This works but lacks a single
  orchestrator and uniform telemetry.

Goal
- Centralize shutdown sequencing and make cleanup phases observable and
  idempotent without changing external behavior.

Tasks (TDD required)
1) Add tests first.
   - Unit tests for the new shutdown orchestrator module.
   - Verify ordering: stop application -> cleanup -> exit.
   - Verify idempotency: repeated cleanup calls are safe.

2) Implement shutdown orchestrator.
   - Introduce a small module (e.g., Snakepit.Shutdown) that:
     - Stops Snakepit based on stop_mode/ownership.
     - Runs RuntimeCleanup with bounded timeout.
     - Emits telemetry for each phase.
   - Update run_as_script/2 to use this orchestrator.
   - Keep Application.stop/1 cleanup hook as a safety net.

3) Telemetry improvements.
   - Add telemetry events for script shutdown phases and exit decisions.
   - Include run_id, exit_mode, and cleanup result metadata.

4) Update docs.
   - Document shutdown phases and telemetry events.
   - Update README.md and relevant guides.

5) Append changes to CHANGELOG.md under the 0.9.0 entry.

Constraints
- Use TDD: tests first, then implementation.
- Keep shutdown behavior backward compatible unless documented.
- Update README and all guides as described in docs/src/05-planning-docs-changelog.md.

