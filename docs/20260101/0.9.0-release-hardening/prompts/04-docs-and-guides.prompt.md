# Prompt 04: Documentation and Guide Alignment

Required reading (docs/src):
- docs/20260101/0.9.0-release-hardening/docs/src/01-research-foundations.md
- docs/20260101/0.9.0-release-hardening/docs/src/03-planning-design.md
- docs/20260101/0.9.0-release-hardening/docs/src/05-planning-docs-changelog.md

Context
- After code changes, docs must be fully aligned with new exit and shutdown
  semantics across README and guides.

Goal
- Ensure all user-facing docs reflect the final 0.9.0 behavior, especially
  exit_mode, stop_mode, and shutdown phases.

Tasks (TDD required)
1) Add documentation tests if available (if not, skip test changes).
2) Update README.md and all guides referencing run_as_script/2 or script mode.
3) Update API docs in docs/20251229/documentation-overhaul/01-core-api.md.
4) Ensure examples/README.md is consistent with the new behavior.
5) Append the final summary to CHANGELOG.md under the 0.9.0 entry.

Constraints
- Keep docs consistent with implemented behavior.
- Update README and all guides as described in docs/src/05-planning-docs-changelog.md.

