  You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
  access, network=enabled, approval_policy=never. Run commands as ["bash","-lc", ...] with explicit workdir; avoid bare `cd`.
  Prefer rg for searches. Use apply_patch for targeted ASCII edits. Never undo user changes or run destructive git commands.
  Stop and ask if unexpected modifications appear. Plan only for multi-step tasks; never produce single-step plans.

  Before coding, reread:
  - docs/20251026/CRITICAL_BUGS.md (items 1–4 & 6 now addressed; focus moves to #5, #7, and related reliability items)
  - lib/snakepit/pool/worker_supervisor.ex (`wait_for_resource_cleanup/4`)
  - lib/snakepit/pool/process_registry.ex (cleanup hooks)
  - lib/snakepit/grpc_worker.ex (port lifecycle references used by cleanup)
  - test/unit/pool/worker_supervisor_test.exs
  - ETS/DETS visibility hardened, shell diagnostics rewritten, and parameter decoding tightened; full suite remains green.
  - Next priorities per critical bug log: ensure worker restart cleanup handles fixed ports correctly (#5) and address queue
  cancellation/backlog handling (#7).

  Tasks to tackle now:
  1. Refine worker restart port cleanup (#5):
     - Update `WorkerSupervisor.wait_for_resource_cleanup/4` to conditionally probe port availability only when a specific
  port (non-zero) was bound.
     - Ensure the logic integrates with the new port-tracking state, handling ephemeral ports gracefully.
     - Extend or add tests validating restart behaviour for both fixed and ephemeral ports.

  2. Audit queue cancellation and backlog handling (#7):
     - Investigate `Snakepit.Pool` queue/cancellation logic for potential unbounded growth or stale entries.
     - Implement pruning/timeout strategies as described in the critical bug doc.
     - Add regression tests covering cancellation churn and queue size limits.

  3. Housekeeping:
     - Update documentation or inline comments only where it clarifies new behaviour.
     - Run targeted tests plus `mix test` as needed; document any skipped verifications in your final summary.

  Follow repo conventions (Elixir two-space indent, minimal comments). Keep new tests close to the code they cover. Summarize
  changes and test results concisely when done.
