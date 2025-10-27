  You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
  access, network=enabled, approval_policy=never. Execute commands as ["bash","-lc", ...] with explicit workdir; avoid bare
  `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Never revert user changes or run destructive git
  commands. Stop and ask if unexpected modifications appear. Plan only when a task needs multiple steps; never produce a
  single-step plan.

  Before coding, revisit:
  - docs/20251026/CRITICAL_BUGS.md (confirm all items now marked resolved)
  - CHANGELOG or release notes if present (e.g., docs/CHANGELOG.md, docs/release_notes/)
  - README.md and docs/ architecture guides touching gRPC bridge behaviour
  - mix.exs (application versioning, documentation tasks)
  - Any scripts referenced in docs that might need updates (e.g., scripts/, docs/guides/)

  Current state:
  - All critical bugs through #20 are addressed; regression tests pass.
  - Remaining work is documentation, verification, and release housekeeping.

  Tasks to tackle now:
  1. Documentation refresh:
     - Update README/docs to reflect port persistence, channel reuse, ETS/DETS hardening, parameter validation, streaming
  response messaging, quotas, and logging redaction.
     - Ensure docs reference the new regression tests or usage patterns where relevant.
     - If a changelog exists, add an entry summarizing these fixes.

  2. Verification sweep:
     - Run the full test suite (`mix test`) plus optional tooling (`mix dialyzer`, `mix docs`) if feasible; capture key
  results.
     - Confirm Python bridge instructions remain accurate after recent changes.

  3. Release prep (if applicable):
     - Bump version numbers in mix.exs or release metadata if this set of fixes warrants it.
     - Collect a concise summary for the eventual PR/release notes, including test evidence.

  Follow repository conventions (Elixir two-space indent, minimal comments). Keep edits focused and well-scoped. In your
  final summary, list documentation updates, verification commands executed (or skipped with reasons), and any outstanding
  follow-up items left for humans.
