# Session Affinity Findings (2026-01-10)

## Executive Summary
Snakepit's session affinity is a best-effort preference, not a guarantee: when the preferred worker is unavailable or tainted it immediately falls back to any available worker or runs queued work on whichever worker checks in. This behavior is documented in guides and unit tests, but README language implies stronger guarantees; there is no Python-side replication or retry for missing in-memory refs, so "Unknown reference" under load is expected.

Note: Findings below reflect the pre-0.9.2 behavior; see the status update at the end for current implementation.

## Methodology
- Traced the execute path from `Snakepit.execute/3` through pool checkout, dispatcher, queue, crash barrier, and gRPC worker execution.
- Reviewed session store and affinity cache implementation, plus pool state/capacity handling.
- Reviewed Python gRPC server and session context for ref sharing or retries.
- Reviewed pool/session tests and documentation.
- Tests not run (analysis only).

## Findings
1. End-to-end routing path: `Snakepit.execute/3` -> `Snakepit.Pool.execute/3` -> `Snakepit.Pool.handle_call/3` -> `Snakepit.Pool.Dispatcher.execute/7` -> `checkout_worker/3` -> `execute_with_crash_barrier/7` -> `Snakepit.GRPCWorker.handle_call/3` -> Python gRPC adapter. (`lib/snakepit.ex:52`, `lib/snakepit/pool/pool.ex:61`, `lib/snakepit/pool/pool.ex:554`, `lib/snakepit/pool/dispatcher.ex:10`, `lib/snakepit/pool/pool.ex:947`, `lib/snakepit/pool/pool.ex:1170`, `lib/snakepit/grpc_worker.ex:308`)
2. Affinity is a preference: `checkout_worker/3` tries the preferred worker if available and not tainted; otherwise it immediately falls back to `next_available_worker/1` and updates affinity. (`lib/snakepit/pool/pool.ex:947`, `lib/snakepit/pool/pool.ex:968`, `lib/snakepit/pool/pool.ex:994`)
3. "Busy" is defined by worker capacity: availability is based on load < capacity, so a preferred worker at capacity is removed from `available` and will not be selected. (`lib/snakepit/pool/state.ex:104`)
4. Queueing is pool-level and not session-aware: requests only queue when no workers are available; queued requests execute on the worker that checks in (or another available one if tainted). (`lib/snakepit/pool/dispatcher.ex:61`, `lib/snakepit/pool/scheduler.ex:4`, `lib/snakepit/pool/event_handler.ex:174`)
5. Tainted/crashed workers are skipped: tainted workers are excluded from preferred and next-available selection; affinity cache entries for dead workers are cleared, but SessionStore last_worker_id remains until updated by a new checkout. (`lib/snakepit/pool/pool.ex:972`, `lib/snakepit/pool/event_handler.ex:78`, `lib/snakepit/crash_barrier.ex:99`, `lib/snakepit/bridge/session_store.ex:378`)
6. Crash-barrier retries can switch workers: retries call `checkout_worker` again, so affinity can change on crash or taint. (`lib/snakepit/pool/pool.ex:1170`, `lib/snakepit/pool/pool.ex:1242`)
7. No ref replication or "ref not found" retry exists: Python server creates a per-request SessionContext and adapter instance; SessionContext only carries session_id and tool proxy. (`priv/python/grpc_server.py:533`, `priv/python/snakepit_bridge/session_context.py:1`) Elixir SessionStore stores last_worker_id only; it does not mirror Python in-memory state. (`lib/snakepit/bridge/session_store.ex:378`)
8. Tests and docs indicate hint semantics: unit test expects fallback when preferred worker is at capacity. (`test/unit/pool/pool_capacity_scheduling_test.exs:101`) Guides explicitly state affinity is a hint. (`guides/session-scoping-rules.md:123`) README wording implies stronger guarantees. (`README.md:70`, `README.md:222`) Docs in `docs/20251229/...` describe "when possible" and fallback. (`docs/20251229/documentation-overhaul/02-workers-sessions.md:380`)
9. No configuration knob for strict affinity: config/defaults only expose cache TTL and general pool/capacity settings. (`lib/snakepit/defaults.ex:1117`, `lib/snakepit/pool/state.ex:152`)

## Answers to Phase 1 Questions
- What happens when preferred worker is busy? If it is still available (load < capacity), it is selected; if it is not available or tainted, `checkout_worker/3` falls back immediately to any available worker. Only if no workers are available does the request queue. (`lib/snakepit/pool/pool.ex:947`, `lib/snakepit/pool/state.ex:104`, `lib/snakepit/pool/scheduler.ex:4`)
- What happens when preferred worker is tainted/crashed? Tainted workers are skipped; crashed workers are removed and affinity cache entries cleared. The next request will pick any available worker and update affinity in SessionStore. (`lib/snakepit/pool/pool.ex:972`, `lib/snakepit/pool/event_handler.ex:78`, `lib/snakepit/bridge/session_store.ex:378`)
- Is there any mechanism to replicate refs across workers? No. Python side constructs per-request session context and adapter instances; SessionContext does not replicate worker memory. (`priv/python/grpc_server.py:533`, `priv/python/snakepit_bridge/session_context.py:1`)
- Is there retry logic for "ref not found" errors? No specific retry exists for application errors. Crash-barrier retries only on worker exits and may choose a different worker. (`lib/snakepit/pool/pool.ex:1170`, `lib/snakepit/crash_barrier.ex:56`)
- Are there configuration options that change this behavior? No strict affinity toggle exists; only cache TTL and capacity/queue settings. (`lib/snakepit/defaults.ex:1117`, `lib/snakepit/pool/state.ex:152`)
- Is this documented behavior or a bug? Documented as a hint in guides and newer docs; unit tests encode fallback behavior. README implies stronger guarantees and should be clarified. (`guides/session-scoping-rules.md:123`, `docs/20251229/documentation-overhaul/02-workers-sessions.md:380`, `test/unit/pool/pool_capacity_scheduling_test.exs:101`, `README.md:70`, `README.md:222`)

## Verdict
NEEDS DOCUMENTATION. The implementation intentionally treats affinity as best-effort; the behavior is not a code defect relative to internal docs/tests, but README language suggests a stronger guarantee than provided. For stateful Python refs that require strict pinning, current behavior can produce "Unknown reference" under load; that limitation should be explicitly documented, or a strict-affinity mode added as a future enhancement.

## Status Update (0.9.2)
The remediation was implemented in v0.9.2:
- Strict affinity modes were added and enforced in pool checkout (`:strict_queue` / `:strict_fail_fast`). (`lib/snakepit/pool/pool.ex:1021`)
- Queue dispatch is now affinity-aware so pinned requests wait for their worker. (`lib/snakepit/pool/queue.ex:85`)
- `affinity` is validated/normalized and defaults to `:hint`. (`lib/snakepit/config.ex:440`, `lib/snakepit/defaults.ex:1129`)
- README and guides now document hint vs strict behavior and error modes. (`README.md:220`)
