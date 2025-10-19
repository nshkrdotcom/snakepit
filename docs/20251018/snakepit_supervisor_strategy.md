# Snakepit Supervisor Strategy  
_Created: 2025-10-18_  

## Executive Overview

- Snakepit’s supervision layer exists to guarantee bounded failure domains between BEAM-side orchestration and external Python workers.  
- The orchestration stack relies on layered OTP supervisors that separate lifecycle control (pool, worker startup) from cross-language bridge infrastructure (gRPC listeners, telemetry back-pressure).  
- A coherent strategy emphasises deterministic restarts, observability of escalations, and the ability to inject richer lifecycle primitives (heartbeat, watchdog, reclaim logic) without destabilising the tree.  

## Existing Supervision Layout

- **`Snakepit.Application`** anchors the tree with a top-level `Supervisor` using `:one_for_one`. It boots configuration providers, registries, and the pool subsystem.  
- **Configuration & Registry Layer** (`Snakepit.Config.Server`, `Snakepit.Pool.ProcessRegistry`) initialise before any worker-facing component to ensure subsequent crashes retain consistent configuration snapshots.  
- **Pool Control Plane** splits between `Snakepit.Pool.Supervisor` (a dynamic supervisor owning worker supervisors) and `Snakepit.Pool.WorkerStarter` (task supervisor for async launches). Each uses `:rest_for_one` semantics within its sub-tree to restart dependent resources predictably.  
- **Worker Execution Plane** leverages a per-worker `Supervisor` wrapping `Snakepit.GRPCWorker`, telemetry processes, and optional adapters (heartbeat monitor integration pending).  
- **Bridge Utilities** (gRPC endpoints, ingest pipelines) sit under dedicated supervisors so that network instability restarts do not propagate to pools unless escalation rules trigger.  

## Strategic Review Findings

- **Resilience Posture:** The layered approach is sound; crash isolation prevents cascading restarts across pool boundaries. However, heartbeat/watchdog additions must maintain supervisor boundaries by colocating monitors with workers rather than at the pool level.  
- **Configurability:** Hot-reload of worker parameters currently depends on the config server. Introducing runtime toggles (e.g., heartbeat thresholds) should keep config providers at the top level to avoid churn.  
- **Observability:** Supervisor hierarchies already emit telemetry on restarts, but the strategy should formalise per-layer event naming so future automation (pager rules, dashboards) can correlate worker, pool, and global restarts.  
- **Recovery Semantics:** Dynamic supervisors spawn workers individually, supporting quick reclaim. Ensure the upcoming heartbeat escalation path terminates workers through supervisor-coordinated shutdowns, preserving restart intensity limits.  
- **Testing & Validation:** Keep property-based restart simulations alongside unit suites. The current structure supports controlled chaos testing by killing specific supervisors; the strategy should document these scenarios for the QA playbook.  

## Recommendations

- Codify supervisor contracts in `docs/architecture/supervision.md` (or equivalent) once heartbeat work lands, capturing which processes may terminate each layer.  
- Adopt telemetry naming conventions (`:snakepit, :pool_supervisor, :terminate`) and require new supervisors to emit structured metadata (pool id, worker id).  
- Before adding new OTP children, evaluate whether they belong in the control plane (pool-wide impact) or execution plane (per worker). Maintain single responsibility per supervisor to keep restart decisions predictable.  
- Extend integration tests to cover supervisor restarts (e.g., `mix test --only supervisor_recovery`). Leverage `StreamData` to fuzz child crashes and validate isolation guarantees.  
- Review the restart intensity configuration quarterly as Python bridge load evolves; align limits with the heaviest production workloads to avoid thrashing under high churn.  
