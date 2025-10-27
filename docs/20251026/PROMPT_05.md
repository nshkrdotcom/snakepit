  You are Codex (GPT-5) continuing work in the snakepit repo at /home/home/p/g/n/snakepit with sandbox_mode=danger-full-
  access, network=enabled, approval_policy=never. Run commands as ["bash","-lc", ...] with explicit workdir; avoid bare
  `cd`. Prefer rg for searches. Use apply_patch for targeted ASCII edits. Never revert user changes or run destructive git
  commands. Stop and ask if unexpected modifications appear. Plan only when a task needs multiple steps; never produce a
  single-step plan.

  Before coding, reread:
  - docs/20251026/CRITICAL_BUGS.md (items 1–11 handled; focus now on performance, portability, and API hygiene items 12–20)
  - lib/snakepit/grpc/bridge_server.ex (streaming handler, encode/decode symmetry)
  - lib/snakepit/grpc/client_impl.ex (parameter encoding, execute_tool/5)
  - lib/snakepit/pool/pool.ex (extract_pool_name/1 and logging)
  - mix/tasks/diagnose.scaling.ex (ensure previous refactors remain compatible with upcoming changes)
  - lib/snakepit/process_killer.ex (if additional logging/redaction is needed)
  - tests under test/snakepit/grpc/, test/unit/grpc/, and any pool utility tests related to parameter handling or worker
  naming

  Current state:
  - gRPC port persistence, channel reuse, ETS/DETS hardening, diagnostics, parameter decoding robustness, restart cleanup,
  Tasks to tackle next:
  1. Improve streaming response handling (Critical bug #17):
     - Update `BridgeServer.execute_streaming_tool/2` to return a well-formed `UNIMPLEMENTED` error with actionable guidance,
  or implement minimal streaming support if feasible.
     - Add regression tests confirming the new behaviour (e.g., exercising the RPC and asserting on the status/message).

  2. Harden parameter encoding paths (Critical bugs #18 & #19):
     - Update `Snakepit.GRPC.ClientImpl.infer_and_encode_any/1` (and related helpers) to reject non-JSON-serializable terms
  gracefully, returning a clear error tuple.
     - Ensure `BridgeServer.encode_tool_result/1` and `decode_tool_parameters/1` remain symmetric and raise/return errors
  consistently when payloads are malformed.
     - Add unit tests covering invalid parameter types and mismatched encode/decode scenarios.

  3. Refine pool worker name extraction (Critical bug #20):
     - Review `Snakepit.Pool.extract_pool_name_from_worker_id/1` to avoid silently defaulting to `:default`. Consider
  tracking pool metadata instead of parsing strings; at minimum, log warnings and propagate errors upstream.
     - Add tests ensuring mislabelled worker IDs surface actionable warnings/errors.

  4. Optional performance follow-up (Critical bug #12 already mitigated via channel reuse, but re-verify no regressions):
     - Review current channel reuse implementation and ensure any new changes preserve long-lived connections; adjust tests
  if necessary.

  Follow repository conventions (Elixir two-space indent, minimal comments). Place new tests near the code they cover. Run
  focused suites plus `mix test`; if something can’t be executed, explain why in your final summary. Provide concise change
  notes and test results when done.
