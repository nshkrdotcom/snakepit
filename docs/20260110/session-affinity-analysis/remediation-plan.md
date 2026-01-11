# Remediation Plan (Implemented in 0.9.2)

## Goal
Provide explicit documentation for hint behavior and add strict affinity options for stateful, in-memory Python refs.

## Status (0.9.2)
- Docs now clarify hint vs strict affinity and the implications for in-memory refs. (`README.md:220`, `guides/session-scoping-rules.md:129`, `guides/configuration.md:135`)
- Config/defaults include `affinity` with strict modes. (`lib/snakepit/config.ex:440`, `lib/snakepit/defaults.ex:1129`)
- Strict queue pins requests to the preferred worker; strict fail-fast returns `{:error, :worker_busy}` when that worker is busy. (`lib/snakepit/pool/pool.ex:1021`)
- Queue dispatch is affinity-aware to avoid running pinned work on the wrong worker. (`lib/snakepit/pool/queue.ex:85`)
- Tests and example added for strict affinity behavior. (`test/unit/pool/pool_affinity_strict_test.exs:1`, `examples/grpc_session_affinity_modes.exs:1`)
