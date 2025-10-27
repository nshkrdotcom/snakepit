  You are Codex (GPT-5) working in the snakepit repository at /home/home/p/g/n/snakepit. Environment: sandbox_mode=danger-
  full-access, network=enabled, approval_policy=never. Invoke shell commands as ["bash","-lc", ...] with workdir explicitly
  set; don’t rely on bare `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Never revert user changes
  or run destructive git commands. Stop immediately if you spot unexpected modifications. Plan only for multi-step tasks,
  never produce a single-step plan.

  Before making changes, review:
  - docs/20251026/CRITICAL_BUGS.md (items 1 & 2 are resolved; focus on items 3–6 next).
  - lib/snakepit/bridge/tool_registry.ex (ETS usage and visibility).
  - lib/snakepit/bridge/session_store.ex (or equivalent module handling the `:snakepit_sessions` table).
  - lib/snakepit/pool/process_registry.ex (DETS handle usage, table visibility).
  - mix/tasks/diagnose.scaling.ex (shell-dependent diagnostics).
  - lib/snakepit/process_killer.ex (shell pipeline logic).
  - tests covering these areas, especially under `test/bridge/` and `test/pool/`.

  Context from the previous session:
  - GRPC workers now persist their runtime ports and BridgeServer reuses worker channels, with regression tests passing (`mix
  test` yielded 7 doctests, 185 tests, 0 failures, 3 excluded, 2 skipped).

  Tasks to tackle now:
  1. Harden ETS and DETS usage (Critical bug #3):
     - Change the relevant ETS tables (session store, tool registry, worker capacity) from `:public` to `:protected`.
     - Ensure all writes go through the owning GenServer; adjust code/tests accordingly.
     - Make the DETS table handle private (avoid exposing a named atom globally).
     - Add or update tests that touch these APIs to ensure access still works and unauthorized writes are prevented.

  2. Reduce brittle shell dependencies (Critical bug #4):
     - Inspect `Mix.Tasks.Diagnose.Scaling` and `Snakepit.ProcessKiller` for shell pipelines relying on `sh`, `ss`, `grep`,
  etc.
     - Replace with Erlang/Elixir-native approaches or guard the commands behind platform checks with clear fallbacks.
     - Update docs or inline comments only when it truly clarifies the change.
     - Add regression coverage (unit or integration tests) to prove the new approach works.

  3. Improve parameter decoding robustness (Critical bug #6):
     - In `Snakepit.GRPC.BridgeServer.decode_tool_parameters/1`, fail fast or return a clear error when JSON decoding fails
  instead of passing raw values.
     - Ensure symmetry with encoding (`encode_tool_result/1`) and update tests to cover malformed payload scenarios.

  As you complete each task:
  - Keep idiomatic Elixir style (two-space indent).
  - Place new tests next to the code they exercise.
    You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
    access, network=enabled, approval_policy=never. Invoke shell commands as ["bash","-lc", ...] with explicit workdir;
    avoid manual `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Do not revert user changes or run
    destructive git commands. Halt and ask if unknown modifications appear. Plan only when the task warrants multiple steps;
    never produce single-step plans.

    Before coding, reread:
    - docs/20251026/CRITICAL_BUGS.md (items 1 & 2 resolved; focus now shifts to remaining issues starting at #3)
    - lib/snakepit/grpc_worker.ex (port tracking logic around handle_continue/3)
    - lib/snakepit/grpc/bridge_server.ex (channel management helpers ensure_worker_channel/1, tool_call_options/1)
    - test/unit/grpc/grpc_worker_ephemeral_port_test.exs
    - test/snakepit/grpc/bridge_server_test.exs
    - test/support/mock_adapters.ex (EphemeralPort adapter)
    - test/support/mock_grpc_server_ephemeral.sh

    Current state:
    - Port persistence and channel reuse are fixed with regression tests green (`mix test` recently yielded 7 doctests, 185
    tests, 0 failures, 3 excluded, 2 skipped).
    - Remaining critical items include locking down ETS/DETS visibility, hardening shell-dependent diagnostics, and
  improving
    parameter decoding, per the updated critical bug doc.

    Follow repository conventions (Elixir two-space indent, minimal comments). When altering behaviour, add or update nearby
    tests. Run `mix test` or scoped equivalents to validate; if unable, note why. Provide concise summaries of changes and
    verification results when finishing.
