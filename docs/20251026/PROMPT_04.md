  You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
  access, network=enabled, approval_policy=never. Run commands as ["bash","-lc", ...] with explicit workdir; avoid bare
  `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Never revert user changes or run destructive git
  commands. Stop and ask if you notice unexpected modifications. Plan only when a task needs multiple steps; never produce a
  single-step plan.

  Before coding, reread:
  - docs/20251026/CRITICAL_BUGS.md (items 1–7 resolved; focus now on items 8–11)
  - lib/snakepit/pool/pool.ex (especially execute/3, telemetry, queue management)
  - lib/snakepit/pool/process_registry.ex (worker metadata, cleanup)
  - lib/snakepit/bridge/tool_registry.ex (tool registration paths)
  - lib/snakepit/bridge/session_store.ex (session/global program storage)
  - lib/snakepit/logger.ex or any logging helpers used for redaction
  - tests under test/unit/pool/, test/unit/bridge/, and any existing logging/telemetry coverage

  Current state:
  - gRPC port persistence, channel reuse, ETS/DETS hardening, shell diagnostics, parameter decoding, restart cleanup, and
  `:DOWN`. Ensure telemetry reflects the early exit.
     - Add regression tests simulating a client crashing before completion and assert no costly execution happens.

  2. Harden tool registration inputs (Critical bug #9):
     - Introduce validation in `ToolRegistry.register_tools/2` (and related APIs) for tool names, metadata size, and
  duplicates.
     - Update BridgeServer or adapters if necessary to surface errors cleanly.
     - Add tests covering invalid names/oversized metadata and duplicate registration attempts.

  3. Enforce session/global program quotas (Critical bug #10):
     - Implement configurable limits in `SessionStore` (or relevant module) for per-session tools/programs and overall
  counts.
     - Return explicit errors when quotas are exceeded and ensure TTL cleanup still works.
     - Extend tests to cover quota enforcement and TTL behaviour.

  4. (Optional but recommended) Scrub sensitive log output (Critical bug #11):
     - Audit high-volume log statements (Python spawn command, tool args, heartbeat env) and apply redaction helpers.
     - Add unit tests for the redaction helper if you create one.

  Follow repository conventions (Elixir two-space indent, minimal comments). Place new tests near the code they cover. Run
  focused suites plus `mix test`; if anything can’t be executed, document why in your summary. Provide concise change and
  test notes when you finish.
