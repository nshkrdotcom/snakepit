This is a significant architectural pivot. Currently, `snakepit` effectively functions as a sophisticated **Process Manager** (a "sidecar" or "kubelet" model) where the Erlang VM and the Python workers share the same physical memory space and OS kernel.

Moving to a **Distributed System** changes the fundamental constraints:
1.  **Latency:** Message passing moves from microseconds (local PID) to milliseconds (network).
2.  **State:** Shared memory (Zero-copy/DLPack) is no longer guaranteed.
3.  **Failure Modes:** Partitions (Netsplits) and partial node failures are now possible.

As a Senior Fellow Engineer, here is the critical analysis and architectural blueprint for refactoring `snakepit` into a distributed substrate.

---

### 1. The Global Registry & Service Discovery
**Current State:** `Snakepit.Pool.Registry` uses local `Registry` (:unique).
**The Problem:** Node A doesn't know Worker X exists on Node B.

**Proposed Architecture:**
We need a **Cluster-wide Registry**.
*   **Technology:** Replace local `Registry` with **Horde** (CRDT-based distributed registry) or **Syn**.
*   **Mechanism:**
    *   When `Snakepit.GRPCWorker` starts, it registers itself in the global registry tagged with metadata: `{:node, :pool_name, :capabilities}`.
    *   This allows `Snakepit.execute(worker_id, ...)` to function transparently across the cluster using standard Erlang distribution mechanisms.

**Feasibility:** High. The existing `Snakepit.Pool.Registry` module acts as a facade. We can swap the implementation details there with minimal impact to the call sites, provided we handle the eventual consistency of CRDTs.

### 2. Distributed Session Management (The "State" Problem)
**Current State:** `Snakepit.Bridge.SessionStore` uses a local ETS table.
**The Problem:** A session created on Node A is invisible to Node B. If Node A dies, the session metadata is lost.

**Proposed Architecture:**
Refactor `SessionStore` into a **Partitioned Stateful Entity**.
*   **Sharding:** Use consistent hashing (e.g., `libring`) based on `session_id` to determine which Node "owns" the session metadata.
*   **The Session Actor:** Instead of a passive ETS table, a `Session` becomes a `GenServer` (supervised by `Horde.DynamicSupervisor`).
    *   It holds the state (affinity mapping, tool definitions).
    *   It acts as the gateway. You send the command to the *Session Process*, and the Session Process routes it to the specific Worker it has affinity with.
    *   **Failover:** If the Node hosting the Session Process dies, Horde restarts it on another node.

**Critical Consideration:** While we can recover the *metadata* (which worker has the session), we cannot easily recover the *Python Memory State* if the node hosting the Python worker dies. The architecture must accept that **Worker Death = Session State Loss** unless the Python side implements checkpointing (e.g., serializing to S3/Redis).

### 3. The Global Scheduler (Pool Coordination)
**Current State:** `Snakepit.Pool` manages a local queue and local worker checkout.
**The Problem:** One node might be saturated while another is idle.

**Proposed Architecture:**
Implement a **Two-Layer Scheduling** system.

*   **Layer 1 (Global Router):**
    *   Stateless facade. When a request comes in:
    *   *If Session Affinity exists:* Route directly to the specific Node/Worker.
    *   *If Stateless:* Use **Join-the-Shortest-Queue (JSQ)** or **Power-of-Two-Choices** to select a target Node based on broadcasted load metrics.
*   **Layer 2 (Local Pool):**
    *   Keep the existing `Snakepit.Pool` logic (Queue, Checkout, Backpressure) exactly as is, but serving only requests routed to this node.

**Telemetry Integration:**
Nodes must gossip their capacity stats (e.g., via `Phoenix.PubSub` or `pg`).
*   `Snakepit.Pool.get_stats/1` needs to become cluster-aware, aggregating data from all nodes.

### 4. Zero-Copy & Data Plane Implications
**Current State:** `Snakepit.ZeroCopy` uses `NIF` resources (Arrow/DLPack) passed via memory reference.
**The Constraint:** You cannot send a pointer over the network.

**Modifications:**
*   **Strict Locality:** The API must return an error if a user attempts to use Zero-Copy on a remote session.
*   **Smart Routing:** The Scheduler *must* route requests containing `ZeroCopyRef` to the local node if possible, or reject them.
*   **Fallback Serialization:** Implement an automatic fallback (possibly via Arrow Flight) to serialize data over the wire if locality cannot be satisfied, warning the user about the performance hit.

### 5. Resiliency & Circuit Breaking
**Current State:** Local `Snakepit.CircuitBreaker`.

**Modifications:**
*   **Distributed Circuit Breaking:** If Node A detects Node B's workers are failing (e.g., network partition), Node A needs to stop routing traffic there.
*   **Network Partition Handling:**
    *   Using distributed Erlang, if a netsplit occurs, we risk "Split Brain" on session ownership.
    *   *Decision:* Prioritize Availability (AP). Allow sessions to be re-instantiated on the healthy side, accepting that the old "zombie" python process might still be alive on the partitioned node until the partition heals (or a heartbeat kills it).

### 6. Codebase Impact Analysis

Here is the "Senior Engineer" refactor punch list based on the provided file structure:

1.  **`snakepit/pool/registry.ex`**:
    *   Rewrite to wrap `Horde.Registry`.
    *   Add cluster awareness to lookup functions.

2.  **`snakepit/bridge/session_store.ex`**:
    *   **Deprecate ETS**.
    *   Refactor into a `SessionSupervisor` (Horde) spawning individual `Session` GenServers.
    *   Move the logic from `Snakepit.Pool.try_checkout_preferred_worker` into this Session GenServer.

3.  **`snakepit/pool.ex` (The Dispatcher)**:
    *   Modify `execute/3` to perform the "Layer 1" routing decision (Local vs Remote).
    *   If remote, use `GenServer.call({Name, Node}, ...)` instead of local PID.

4.  **`snakepit/grpc_worker.ex`**:
    *   Add `Node` metadata to the worker state.
    *   Implement "Zombie Killing": If the global registry says this worker shouldn't exist (e.g., after a netsplit healing), it should self-terminate.

5.  **`snakepit/heartbeat_monitor.ex`**:
    *   Must remain **local**. A node must monitor its own Python children. You cannot reliably heartbeat a Python process over a distributed link without false positives.

### Feasibility Verdict

**Status:** Feasible, but high complexity.

**The biggest risk is not the Elixir code, but the Python state.**
In the current "kubelet" model, if Elixir dies, Python dies (via `ApplicationCleanup`). In a distributed model, if the "Owner" node of a session changes, the physical Python process holding the ML model weights is still on the old node.

**Recommendation:**
Do not try to migrate live Python workers.
1.  **Stateless Pools:** Trivial. Distribute requests via standard load balancing.
2.  **Stateful Sessions:** Sticky Sessions are mandatory.
    *   The `SessionId` must map to a specific Node.
    *   If that Node dies, the Session is **Dead**.
    *   Do not attempt to transparently migrate stateful sessions without a shared storage layer (S3/EFS) and application-level checkpointing logic.

### Migration Steps

1.  **Cluster Formation:** Add `libcluster` to allow nodes to mesh.
2.  **Global Registry:** Swap `Pool.Registry` for `Horde`.
3.  **RPC Layer:** Abstract `GenServer.call(pid)` into `Snakepit.Cluster.call(worker_id)`.
4.  **Load Balancer:** Implement the logic to pick a random node for stateless requests.
