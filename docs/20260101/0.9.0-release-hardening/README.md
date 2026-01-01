# Snakepit 0.9.0 Release Hardening

This directory contains research and planning material for a focused 0.9.0
refactor targeting script lifecycle reliability, shutdown behavior, and
production hardening. It also includes implementation prompt files intended to
be executed sequentially.

## Structure

- docs/src/01-research-foundations.md
  Fundamental engineering considerations (BEAM lifecycle, OS signals, IO,
  supervision, and process cleanup). Includes design justifications.
- docs/src/02-research-current-state.md
  Current state audit of Snakepit's lifecycle, shutdown, and example behavior.
- docs/src/03-planning-design.md
  Proposed design changes and scope, with tradeoffs and compatibility notes.
- docs/src/04-planning-test-strategy.md
  TDD approach, test matrix, and harness design.
- docs/src/05-planning-docs-changelog.md
  Documentation update plan and changelog strategy for 0.9.0.
- docs/src/06-prompt-sequence.md
  Ordered list of implementation prompts and intended outcomes.

- prompts/01-exit-semantics.prompt.md
- prompts/02-run_as_script-ownership.prompt.md
- prompts/03-shutdown-cleanup-hardening.prompt.md
- prompts/04-docs-and-guides.prompt.md

## Scope

Research and planning only. Implementation work is deferred to the prompts.

