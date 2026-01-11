# Session Affinity Architecture (2026-01-10)

## Current (0.9.2+)

Client
  -> Snakepit.execute / execute_in_session
    -> Pool.Dispatcher
      -> checkout_worker
         -> preferred worker if available and not tainted
         -> if affinity: :hint -> fall back to any available worker
         -> if affinity: :strict_queue -> enqueue pinned request
         -> if affinity: :strict_fail_fast -> return :worker_busy
    -> execute_with_crash_barrier
      -> GRPCWorker -> Python gRPC server -> adapter (per-request SessionContext)

Queue path:
  Pool queue (affinity-aware) -> worker checkin -> execute next compatible request
  (pinned requests only run on their preferred worker; unpinned requests run anywhere).
