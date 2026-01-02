# AGENTS.md

This repository is **Snakepit**: a high-performance, OTP-native worker pool that supervises **external Python workers** (typically via **gRPC**) and provides session affinity, tool registration/execution, streaming, telemetry, and strong shutdown/orphan-cleanup guarantees.

This document is written for **automated coding agents** (and humans) who will modify the codebase. Follow it strictly to avoid regressions in reliability, compatibility, and performance.

---

## 1) Prime Directive

Snakepit exists to safely and efficiently run work on external processes under Elixir supervision.

**Non-negotiables:**
1. **No orphan Python processes.** Any change must preserve deterministic cleanup on normal shutdown and robust cleanup on crashes.
2. **No atom leaks.** Never create atoms dynamically from untrusted input (especially from Python telemetry/events).
3. **No GenServer bottlenecks.** Do not introduce blocking work in GenServer callbacks; use tasks, async flows, or `receive after` timers.
4. **Backward compatibility matters.** Existing configs and call patterns should keep working unless a breaking change is explicitly planned and documented.

---

## 2) Quick Orientation

### Core modules (read these first for most tasks)
- `snakepit/application.ex` — supervision tree, what starts when `:pooling_enabled` is true
- `snakepit/pool/pool.ex` — pool scheduling, queuing, affinity, multi-pool support
- `snakepit/grpc_worker.ex` — worker lifecycle, Python process spawn/terminate, readiness handshake
- `snakepit/adapters/grpc_python.ex` — adapter contract and gRPC execution/streaming
- `snakepit/pool/process_registry.ex` + `snakepit/process_killer.ex` + `snakepit/runtime_cleanup.ex` — PID tracking and cleanup guarantees
- `snakepit/bridge/session_store.ex` + `snakepit/bridge/tool_registry.ex` — session/tool state and dispatch

### Observability and safety rails
- `snakepit/telemetry/*` — telemetry schemas, safe metadata handling, gRPC stream ingestion
- `snakepit/logger.ex` + `snakepit/logger/redaction.ex` — structured logging and redaction

### Config and defaults
- `snakepit/config.ex` — pool config normalization/validation, multi-pool support
- `snakepit/defaults.ex` — centralized, runtime-configurable defaults (timeouts, limits, etc.)

---

## 3) Local Development Workflow (recommended)

### Bootstrap the environment (dev/CI)
1. `mix deps.get`
2. `mix snakepit.setup`  
   Bootstraps Python tooling, venvs, and gRPC stubs.
3. `mix snakepit.doctor`  
   Verifies the Python + gRPC environment is healthy.

### Useful runtime tasks
- `mix snakepit.status` — report pool status (when pooling is enabled)

### Running tests
- `mix test` (or `MIX_ENV=test mix test`)

If you add new features, add tests or update existing ones. If tests are not present for the area you touched, create targeted tests rather than broad end-to-end suites.

---

## 4) Configuration Contract (do not break casually)

Snakepit supports **legacy single-pool** config and **multi-pool** config.

### Legacy (still supported)
- `config :snakepit, pooling_enabled: true`
- `config :snakepit, adapter_module: ...`
- `config :snakepit, pool_size: ...`
- `config :snakepit, pool_config: %{...}`

### Multi-pool (preferred)
- `config :snakepit, pools: [%{name: ..., worker_profile: ..., pool_size: ...}, ...]`

**Rules for agents:**
- Any new config knob must be:
  1) validated/normalized in `Snakepit.Config`  
  2) given a default in `Snakepit.Defaults` (when appropriate)  
  3) documented in module docs where the config is described  
- Preserve the legacy behavior unless the change is explicitly versioned and documented.

---

## 5) Reliability Invariants (must preserve)

### 5.1 Worker lifecycle and OS process cleanup
- `Snakepit.GRPCWorker` spawns Python via `Port.open/2`.
- OS PIDs are tracked in `Snakepit.Pool.ProcessRegistry` (ETS + DETS).
- Shutdown cleanup is enforced by:
  - worker termination (`terminate/2`)
  - registry cleanup loops
  - bounded cleanup (`Snakepit.RuntimeCleanup`)
  - emergency cleanup (`Snakepit.Pool.ApplicationCleanup`)
- Some modules include race-condition mitigation (startup races, mailbox ordering, port exit ordering, pid reuse checks). Do not remove these without replacing them with equivalent safety.

**Agent checklist when touching worker/process code:**
- Ensure `terminate/2` remains idempotent and safe under partial initialization.
- Ensure process group kill behavior stays correct when enabled.
- Never assume port exit ordering; mailbox races must be handled.
- Avoid introducing new “best-effort” shutdowns without bounded timeouts.

### 5.2 Atom safety (telemetry, metadata, event names)
- Python telemetry and other external inputs must never create new atoms at runtime.
- Event and measurement keys must pass allowlists in:
  - `Snakepit.Telemetry.Naming`
  - `Snakepit.Telemetry.SafeMetadata`

**Agent rule:** if you add a new Python-originated telemetry event:
1. Add it to `Snakepit.Telemetry.Naming` (event parts → event atoms).
2. Add measurement keys to the allowlist if needed.
3. Add any metadata keys to `SafeMetadata` allowlist *only if safe*.

### 5.3 Performance constraints
- The pool path is hot. Avoid:
  - per-request heavy allocations
  - large term copying
  - synchronous file I/O in request paths
  - blocking `GenServer.call` chains without timeouts

Prefer ETS for read-heavy shared state; prefer tasks for blocking work.

---

## 6) How to Make Common Changes

### 6.1 Add a new Python adapter
- Implement the `Snakepit.Adapter` behaviour (`executable_path/0`, `script_path/0`, `script_args/0`).
- Use `mix snakepit.gen.adapter <name>` to scaffold Python-side structure (under `priv/python/...`) if applicable.
- Ensure `Snakepit.EnvDoctor` can validate adapter imports if you expect it to be used in CI/dev workflows.
- Provide minimal example tools and a basic health check path.

### 6.2 Add a new tool type (Elixir or Python)
- Python tools are registered through the bridge (`register_tools`) and stored in `Snakepit.Bridge.ToolRegistry`.
- Elixir tools can be registered as local handlers and optionally exposed to Python.
- Ensure tool naming constraints remain enforced (length, charset, no untrusted atom creation).

### 6.3 Extend pool scheduling/capacity logic
- Keep decisions deterministic and testable.
- Preserve fairness and queue timeout semantics.
- If you introduce a new capacity strategy:
  - keep the default unchanged
  - add metrics/telemetry for validation
  - document the strategy in `Snakepit.Pool` and `Snakepit.Config`

### 6.4 Add/modify timeouts
- Prefer routing timeout defaults through `Snakepit.Defaults`.
- Ensure inner timeouts are less than outer call timeouts (see `Defaults.rpc_timeout/1`).
- When adding a timeout: document which layer it governs (queue wait vs RPC vs shutdown).

---

## 7) Logging and Debugging Guidance

Snakepit logging is intentionally quiet by default.
- Global level: `config :snakepit, log_level: :error | :warning | :info | :debug | :none`
- Category filters: `config :snakepit, log_categories: [:pool, :grpc, ...]`
- For tests, prefer process-scoped overrides via `Snakepit.Logger.set_process_level/1`.

When debugging startup/race issues:
- enable `:debug` logs for `:pool` and `:grpc`
- do not add noisy logs in hot paths permanently; add targeted logs guarded by category/level.

---

## 8) Change Discipline for Agents

### 8.1 Make minimal, surgical edits
- Avoid large refactors unless explicitly requested.
- Preserve existing public function signatures and behavior where possible.
- Prefer incremental improvements with tests.

### 8.2 Always update the right source files
If you are viewing a “packed”/merged representation of the repo, treat it as read-only.
Changes must be made in the actual repository files.

### 8.3 Test before declaring done
At minimum:
- run `mix format` if you touched Elixir code
- run `mix test` (or targeted tests) for touched areas
- if you touched Python runtime/bootstrap paths, run `mix snakepit.doctor` in dev contexts when possible

---

## 9) Pull Request / Patch Checklist (agent self-review)

Before finalizing a change:
- [ ] Does shutdown still clean up Python processes reliably?
- [ ] Did I avoid introducing atom creation from external input?
- [ ] Did I avoid blocking GenServer callbacks on slow operations?
- [ ] Did I preserve legacy configuration behavior?
- [ ] Did I update `Defaults`/`Config`/docs for any new knobs?
- [ ] Did I add or update tests for the change?
- [ ] Did I avoid excessive logging in hot paths?
- [ ] Are telemetry additions atom-safe and schema-consistent?

---

## 10) Philosophy (why the repo is “big”)

Snakepit is not just a pool; it is a **reliable polyglot worker runtime**. The code size largely reflects:
- correct OS process lifecycle management
- gRPC streaming and bridge semantics
- multi-pool + capacity profiles
- observability and safe telemetry ingestion
- environment bootstrapping for reproducibility

Agents should optimize for **correctness under concurrency and failure**, not for cosmetic minimalism.
