# Prompt Sequence

This sequence is designed for incremental, test-driven implementation with
clear checkpoints and minimal cross-step conflicts.

1) prompts/01-exit-semantics.prompt.md
   - Introduce exit_mode and IO-safe exit handling.
   - Add tests for exit selection and basic integration behavior.

2) prompts/02-run_as_script-ownership.prompt.md
   - Add ownership-aware stop behavior (stop_mode).
   - Add tests for embedded vs standalone behavior.

3) prompts/03-shutdown-cleanup-hardening.prompt.md
   - Improve shutdown pipeline consistency and telemetry for cleanup phases.
   - Ensure exit path avoids IO and documents cleanup tiers.

4) prompts/04-docs-and-guides.prompt.md
   - Full docs pass to ensure guides and README reflect final behavior.
   - Update 0.9.0 changelog summary once final behavior is known.

Each prompt includes required reading (docs/src), context, and TDD steps.
Each prompt must update README, guides, and append to the 0.9.0 CHANGELOG
entry in addition to code/tests.

