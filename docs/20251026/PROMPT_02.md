  You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
  access, network=enabled, approval_policy=never. Invoke shell commands as ["bash","-lc", ...] with explicit workdir;
  avoid manual `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Do not revert user changes or run
  destructive git commands. Halt and ask if unknown modifications appear. Plan only when the task warrants multiple steps;
  never produce single-step plans.

  Before coding, reread:
  - docs/20251026/CRITICAL_BUGS.md (items 1 & 2 resolved; focus now on items 3–6)
  - lib/snakepit/grpc_worker.ex (handle_continue/3 around port tracking)
  - lib/snakepit/grpc/bridge_server.ex (ensure_worker_channel/1, tool_call_options/1)
  - lib/snakepit/bridge/tool_registry.ex (ETS table management)
  - lib/snakepit/bridge/session_store.ex (session ETS visibility)
  - lib/snakepit/pool/process_registry.ex (DETS access patterns)
  - mix/tasks/diagnose.scaling.ex (shell-heavy diagnostics)
  - lib/snakepit/process_killer.ex (shell pipeline usage)
  - test/unit/grpc/grpc_worker_ephemeral_port_test.exs
  - test/snakepit/grpc/bridge_server_test.exs
  - test/support/mock_adapters.ex (EphemeralPort adapter)
  - test/support/mock_grpc_server_ephemeral.sh
  - Port persistence and channel reuse are fixed with regression tests green (`mix test` recently yielded 7 doctests, 185
  tests, 0 failures, 3 excluded, 2 skipped).
  - Remaining high-priority items: secure ETS/DETS visibility, remove brittle shell dependencies, and harden parameter
  decoding (see docs/20251026/CRITICAL_BUGS.md items 3–6).

  Tasks to tackle next:
  1. Harden ETS/DETS visibility (#3):
     - Change relevant ETS tables from :public to :protected and ensure writes remain internal.
     - Hide the DETS table identifier; store the handle in state, not as a global atom.
     - Update affected modules/tests so read/write flows still pass, adding coverage if missing.

  2. Replace brittle shell diagnostics (#4):
     - Refactor `Mix.Tasks.Diagnose.Scaling` and `Snakepit.ProcessKiller` to rely on Erlang/Elixir APIs or guarded platform
  checks instead of fragile shell pipelines.
     - Document behaviour changes only when they clarify usage.
     - Add regression tests or adjust existing ones to exercise the new logic.

  3. Tighten tool parameter decoding (#6):
     - Update `Snakepit.GRPC.BridgeServer.decode_tool_parameters/1` to fail fast on malformed JSON rather than returning
  raw bytes.
     - Ensure symmetry with `encode_tool_result/1` and create tests covering malformed payloads.

  Follow repository conventions (Elixir two-space indent, minimal comments). When altering behaviour, add or update nearby
  tests. Run `mix test` or scoped equivalents to validate; if unable, note why. Provide concise summaries of changes and
  verification results when finishing.

