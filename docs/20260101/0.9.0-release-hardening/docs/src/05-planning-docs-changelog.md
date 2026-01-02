# Planning: Documentation and Changelog Updates

All implementation prompts must update documentation to reflect new exit
semantics and lifecycle behavior. This doc enumerates required updates.

## 0) Single source of truth for script semantics (0.9.0)

To prevent drift, the definitive behavioral spec for `run_as_script/2` MUST
live in `docs/20251229/documentation-overhaul/01-core-api.md` under a new
"Script Lifecycle (0.9.0)" section. README and guides may summarize but MUST
NOT redefine precedence or matrices; they should reference the API docs for the
authoritative tables.

That API docs section MUST include:

* Exit Selection Precedence table
* `SNAKEPIT_SCRIPT_EXIT` parsing rules
* Legacy `SNAKEPIT_SCRIPT_HALT` compatibility note (deprecated)
* Status Code Rules
* `stop_mode x exit_mode` matrix (embedded vs standalone)
* Shutdown State Machine
* Telemetry Contract (0.9.0)

## 1) README.md

- Update run_as_script examples to use :exit_mode where appropriate.
- Add a short section on exit modes and when to choose :none/:stop/:halt.
- Add notes about wrapper commands and broken pipes.

## 2) Guides

Update all relevant guides that mention run_as_script or script lifecycle:

- guides/getting-started.md
  - Script Mode section: explain exit modes and safe defaults.

- guides/production.md
  - Script Mode: add exit_mode and stop_mode options.
  - Environment Variables: document SNAKEPIT_SCRIPT_EXIT.

- docs/20251229/documentation-overhaul/01-core-api.md
  - Update run_as_script/2 docs to reflect exit_mode, stop_mode, and
    clarify System.halt vs System.stop semantics.

- examples/README.md
  - Ensure example runner description aligns with new defaults.

## 2.1) Telemetry Contract (0.9.0)

Prompt 03 introduces new telemetry for shutdown phases. Docs must define the
telemetry contract in one place (API docs as the source of truth) and ensure
README/guides reference it.

Minimum required documentation:

* Event prefix and naming convention (final decision recorded explicitly).
* Required metadata keys across all shutdown events: `run_id`, `exit_mode`,
  `stop_mode`, `owned?`, `status`, and `cleanup_result`.
* A short "how to consume" note: attach `:telemetry` handlers and what to
  expect in metadata.

If final event names are not known until implementation lands, include an
explicit placeholder table that MUST be finalized in prompt 04 before merge.

## 3) CHANGELOG.md (authoritative workflow)

* Maintain a single `## 0.9.0 - Unreleased` section.
* Within it, maintain subheadings exactly: `### Added`, `### Changed`,
  `### Fixed` (in that order).
* Prompt 01 may create the `0.9.0 - Unreleased` section only if it does not
  already exist.
* Prompts 02-04 MUST only append items under the existing `Added/Changed/Fixed`
  subheadings and MUST NOT create additional `0.9.0` sections.
* Prompt 04 may edit/reword prior bullets for release quality, but must
  preserve the canonical structure and avoid duplicating entries.

## 4) Documentation tone

- Emphasize explicit exit behavior selection.
- Include safe defaults for scripts and embedded runtimes.
- Note deprecations or compatibility behavior for :halt.
