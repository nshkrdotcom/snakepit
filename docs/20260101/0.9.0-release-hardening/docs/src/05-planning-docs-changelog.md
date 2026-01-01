# Planning: Documentation and Changelog Updates

All implementation prompts must update documentation to reflect new exit
semantics and lifecycle behavior. This doc enumerates required updates.

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

## 3) CHANGELOG.md

- Append entries to a new 0.9.0 section.
- Include the following categories:
  - Added: exit_mode option, stop_mode option, new env var.
  - Changed: run_as_script ownership-aware shutdown behavior.
  - Fixed: script exit hang when stdout/stderr is closed or piped.

## 4) Documentation tone

- Emphasize explicit exit behavior selection.
- Include safe defaults for scripts and embedded runtimes.
- Note deprecations or compatibility behavior for :halt.

