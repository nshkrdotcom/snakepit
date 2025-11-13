# ADR 002: Distributed Control Plane Roadmap

**Status:** Proposed  
**Date:** 2025-11-13

## Context

Snakepit currently runs as a single BEAM node per host. Each node owns:

- `Snakepit.Pool` plus the worker supervisors and registries (`Pool.Registry`, `ProcessRegistry`, `Worker.StarterRegistry`).
- Heartbeat monitoring via `Snakepit.HeartbeatMonitor` with push-style pings from Elixir into the local Python processes.
- Lifecycle management (`Snakepit.Worker.LifecycleManager`) that reasons about TTL, request budgets, and BEAM-side memory usage.

This architecture is battle-tested for one node (or a handful of nodes behind an external scheduler), but there is no distributed control plane. Operators who want to coordinate pools across a region must layer their own orchestration on top.

## Forces & Constraints

- Keep the **data-plane** (BEAM node + Python workers on the same host) self-contained so a node can still start, recycle workers, and clean up rogue processes autonomously.
- The future **control-plane** should orchestrate pool sizes, rolling restarts, and health aggregation across nodes without assuming low-latency cluster RPC between nodes.
- Heartbeats today are *push-style* pings from BEAM to Python. They work well on a single host but are not WAN-aware. We want to keep that simple mechanism while providing room for higher-level “evidence of work” (telemetry, request success) at the control plane.
- Registries (`Pool.Registry`, `ProcessRegistry`) are ETS/DETS backed and not yet ready for partitioned/global operation.

## Proposed Direction

1. **Control-plane / Data-plane split**
   - Introduce a control-plane service (or supervisor tree) responsible for deciding desired pool sizes, draining workers, and reacting to node-level telemetry.
   - Data-plane nodes expose a narrow API (start worker, stop worker, report health, stream telemetry) that the control-plane can call.

2. **Heartbeat aggregation**
   - Keep the existing per-node ping loop (low latency, fast feedback).
   - Surface heartbeat state plus “evidence of work” (successful requests, telemetry) to the control-plane so it can make quorum-style decisions without requiring cross-node heartbeat gossip.

3. **Registry contracts**
   - Build on the new `Snakepit.Pool.Registry.fetch_worker/1` helpers and DETS-backed process registry so nodes can report their local view without exposing ETS internals.
   - Document the minimal schema needed for a distributed registry service before attempting to shard/mirror it.

4. **Future work (not in this change)**
   - Evaluate WAN-friendly liveness signals (gossip, phi accrual) once the control-plane exists.
   - Add an authenticated RPC surface so the control-plane can drain or scale pools node-by-node.
   - Design a lightweight coordination protocol for moving workers between nodes without killing Python processes mid-request.

## Consequences

- This ADR does **not** ship a distributed implementation today. It records the target architecture so future work can build toward it incrementally.
- Documentation (ARCHITECTURE.md, README_GRPC.md) now explicitly calls out the current single-node heartbeat semantics and the plan to compose them into a higher-level control plane later.
- Subsequent changes should reference this ADR when adding hooks (e.g., telemetry exports, lifecycle counters) that the future control-plane will consume.
