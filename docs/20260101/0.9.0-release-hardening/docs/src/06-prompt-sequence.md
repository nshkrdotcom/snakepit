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

**Documentation update policy (drift control)**

* Prompts 01-03 MAY update only:

  * `docs/20251229/documentation-overhaul/01-core-api.md` (the single source of
    truth tables/sections), and
  * `CHANGELOG.md` (append-only per canonical structure).
* Prompts 01-03 SHOULD NOT update README/guides/examples to avoid conflicting
  intermediate edits and drift.
* Prompt 04 performs the holistic documentation pass (README + guides +
  examples) and reconciles wording against the API docs tables and the final
  implementation.
* If a prompt must touch user-facing docs earlier for correctness, it must
  only add a short, clearly marked "0.9.0 in progress" note and defer full
  rewrites to prompt 04.

**Checkpoint after Prompt 01:** API docs contain the authoritative Exit
Selection Precedence table + Status Code Rules.
**Checkpoint after Prompt 02:** API docs include `stop_mode` semantics and the
`stop_mode x exit_mode` matrix.
**Checkpoint after Prompt 03:** API docs include the Shutdown State Machine
and Telemetry Contract (draft finalized by Prompt 04).
