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
1. Documentation verification gates (do not skip silently).
   - If ExDoc is present and `mix docs` is configured for this repo, add a
     CI/test gate that runs `mix docs` (or an equivalent docs build) and fails
     on errors.
   - If ExDoc is not present/configured, explicitly record "Docs build gate not
     available" in the PR summary and skip adding it.
   - In all cases, add a lightweight consistency check: ensure all references
     to `run_as_script/2`, `:halt`, `exit_mode`, `stop_mode`,
     `SNAKEPIT_SCRIPT_EXIT`, and `SNAKEPIT_SCRIPT_HALT` are updated and
     consistent (e.g., via a repo-wide search and review).

2) Update README.md and guides (holistic pass).
   - README.md:
     - Update examples to use `:exit_mode` (and `:stop_mode` where relevant).
     - Add a short section that links to the authoritative tables in the API
       docs (do not redefine precedence/matrix in README).
     - Add explicit warnings for embedded usage: `:halt`/`:stop` terminate the
       VM.
     - Add notes about wrapper commands and broken pipes (with portability
       caveats: GNU `timeout` may not exist on macOS).
   - guides/getting-started.md and guides/production.md:
     - Ensure terminology and defaults match the API docs tables.
     - Document `SNAKEPIT_SCRIPT_EXIT` and the deprecation of
       `SNAKEPIT_SCRIPT_HALT`.

3) Update API docs in docs/20251229/documentation-overhaul/01-core-api.md.
   - Ensure the "Script Lifecycle (0.9.0)" section contains the authoritative
     tables:
     - Exit Selection Precedence
     - Status Code Rules
     - `stop_mode x exit_mode` matrix
     - Shutdown State Machine
     - Telemetry Contract (final names + metadata keys)

4) Ensure examples/README.md is consistent with the new behavior.

5) Finalize `CHANGELOG.md` under `## 0.9.0 - Unreleased`.
   - Ensure bullets are in the correct buckets (`### Added`, `### Changed`,
     `### Fixed`) and are not duplicated across prompts.
   - Consolidate wording so the entry reads as a single coherent release note.

Constraints
- Keep docs consistent with implemented behavior.
- Update README and all guides as described in docs/src/05-planning-docs-changelog.md.
