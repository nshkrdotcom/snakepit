# Session Scoping Guide

This guide describes how sessions and object references are scoped in Snakepit's Python-Elixir bridge. Understanding these rules helps prevent resource leaks and design efficient stateful workflows.

---

## Table of Contents

1. [Overview](#overview)
2. [Session Lifecycle](#session-lifecycle)
3. [Reference Scoping](#reference-scoping)
4. [Cross-Process Reference Passing](#cross-process-reference-passing)
5. [Recommended Patterns](#recommended-patterns)
6. [Telemetry Events](#telemetry-events)
7. [ZeroCopy References](#zerocopy-references)
8. [Quick Reference](#quick-reference)

---

## Overview

Snakepit uses a **stateless per-request design** for Python adapters, with session state managed entirely on the Elixir side. This provides strong isolation and predictable cleanup semantics.

| Component | Owner | Lifetime |
|-----------|-------|----------|
| Session state | Elixir (SessionStore) | TTL-based |
| Python adapter | gRPC server | Single request |
| Module cache | Python process | Worker lifetime |

---

## Session Lifecycle

### Ownership

- **Elixir SessionStore** is the authoritative owner of session lifecycle
- Sessions are stored in ETS with TTL-based expiration
- Python adapters receive a `session_id` but never own the session

### Configuration

```elixir
# 1 hour default, configurable via application config
config :snakepit, :session_store,
  default_ttl: 3600,        # seconds
  max_sessions: 10_000,     # quota limit
  cleanup_interval: 60_000, # ms between cleanup runs
  strict_mode: false        # enable for dev/test warnings
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `default_ttl` | `integer` | `3600` | Session TTL in seconds |
| `max_sessions` | `integer` | `10_000` | Maximum concurrent sessions |
| `cleanup_interval` | `integer` | `60_000` | Cleanup interval in ms |
| `strict_mode` | `boolean` | `false` | Enable loud warnings on accumulation |

### Automatic Cleanup

Sessions are automatically cleaned up when:

1. **TTL expires**: Session hasn't been accessed within its TTL period
2. **Explicit deletion**: `SessionStore.delete_session/1` is called
3. **Owner process death**: If the owning Elixir process terminates and cleans up

---

## Reference Scoping

### Python Object References

Python adapters are **stateless per-request**:

```
Request arrives → Adapter created → Tool executed → Adapter destroyed
```

This means:
- Each gRPC request creates a fresh adapter instance
- Adapter state is discarded after the request completes
- No Python object references persist across requests

### Module-Level Caching

For expensive resources (ML models, connections), use module-level caching:

```python
# Module-level cache - shared across ALL requests
_model_cache = {}

class MyAdapter(BaseAdapter):
    def initialize(self):
        if "model" not in _model_cache:
            _model_cache["model"] = load_expensive_model()
        self.model = _model_cache["model"]

    def cleanup(self):
        # Don't clear module cache - it's shared
        pass
```

### Session-Scoped State

For per-session state that persists across requests, store it on the Elixir side:

```python
class MyAdapter(BaseAdapter):
    def execute_tool(self, tool_name, args, context):
        # Read session state from Elixir
        state = context.call_elixir_tool("get_session_state", key="my_state")

        # Perform computation
        result = process(state, args)

        # Save updated state back to Elixir
        context.call_elixir_tool("set_session_state", key="my_state", value=result)

        return result
```

---

## Cross-Process Reference Passing

### Can references be passed between Elixir processes?

**Session IDs**: Yes, session IDs are plain strings and can be passed freely.

**Worker Affinity**: Sessions track their `last_worker_id` for affinity. By default this is a hint rather than a hard constraint, so any worker can service any session.

**Affinity Modes** (configurable per pool):
- `:hint` (default) — Prefer the last worker if available; otherwise fall back to any available worker.
- `:strict_queue` — If the preferred worker is busy, queue the request until it becomes available. This can increase latency and queue timeouts under load.
- `:strict_fail_fast` — If the preferred worker is busy, return `{:error, %Snakepit.Error{category: :pool, details: %{reason: :worker_busy}}}` immediately.

If the preferred worker is tainted or missing, strict modes return
`{:error, %Snakepit.Error{category: :pool, details: %{reason: :session_worker_unavailable}}}`
so callers can reinitialize state or create a new session.

### What happens when the owner process dies?

If an Elixir process that created a session terminates:

1. The session remains in the SessionStore until TTL expires
2. Other processes can still access the session by ID
3. Worker affinity is preserved for warm cache hits

For in-memory Python refs (objects stored only inside a worker), use `affinity: :strict_queue` or `:strict_fail_fast`, or isolate sessions in a dedicated pool (or `pool_size: 1`). Hint mode can route to a different worker under load and invalidate those refs.

For cleanup on process death, use a process monitor:

```elixir
defmodule MySessionManager do
  use GenServer

  def init(_) do
    {:ok, session} = SessionStore.create_session(generate_id())
    {:ok, %{session_id: session.id}}
  end

  def terminate(_reason, state) do
    SessionStore.delete_session(state.session_id)
    :ok
  end
end
```

---

## Recommended Patterns

### Short-Lived Sessions (Request-Scoped)

```elixir
def handle_request(params) do
  {:ok, session} = SessionStore.create_session(generate_id(), ttl: 300)

  try do
    result = Snakepit.execute("my_tool", params, session_id: session.id)
    {:ok, result}
  after
    SessionStore.delete_session(session.id)
  end
end
```

### Long-Lived Sessions (User Sessions)

```elixir
def get_or_create_session(user_id) do
  session_id = "user_#{user_id}"

  case SessionStore.get_session(session_id) do
    {:ok, session} -> session
    {:error, :not_found} ->
      {:ok, session} = SessionStore.create_session(session_id, ttl: 3600)
      session
  end
end
```

### Explicit Session Context (For Shared Sessions)

```elixir
defmodule MyApp.SharedSession do
  @moduledoc """
  Manages a shared session for background processing.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_session_id do
    GenServer.call(__MODULE__, :get_session_id)
  end

  def init(_opts) do
    {:ok, session} = SessionStore.create_session(
      "shared_background_session",
      ttl: 86400  # 24 hours
    )
    {:ok, %{session_id: session.id}}
  end

  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end
end
```

---

## Telemetry Events

Monitor session lifecycle with these telemetry events:

### Session Pruned

Emitted when sessions are cleaned up due to TTL expiration.

```elixir
[:snakepit, :bridge, :session, :pruned]
```

| Measurement | Type | Description |
|-------------|------|-------------|
| `count` | `integer` | Number of sessions pruned |
| `remaining_sessions` | `integer` | Sessions remaining after cleanup |

| Metadata | Type | Description |
|----------|------|-------------|
| `reason` | `atom` | `:ttl` or `:overflow` |
| `table_name` | `atom` | ETS table name |

### Accumulation Warning

Emitted when session count exceeds warning thresholds.

```elixir
[:snakepit, :bridge, :session, :accumulation_warning]
```

| Measurement | Type | Description |
|-------------|------|-------------|
| `current_sessions` | `integer` | Current session count |
| `max_sessions` | `integer` | Configured maximum |
| `utilization` | `float` | Percentage of quota used |

| Metadata | Type | Description |
|----------|------|-------------|
| `reason` | `atom` | `:threshold_warning` or `:quota_exceeded` |
| `strict_mode` | `boolean` | Whether strict mode is enabled |

### Strict Mode for Development

Enable strict mode to get loud warnings when sessions accumulate:

```elixir
config :snakepit, :session_store,
  strict_mode: true  # Logs warnings when session count exceeds 80% of max
```

---

## ZeroCopy References

For zero-copy tensor/buffer references (DLPack, Arrow):

- References are **ephemeral** - valid only for the duration of a single request
- The owner (`:elixir` or `:python`) is tracked in the reference metadata
- References cannot be serialized and passed across requests

```elixir
# ZeroCopy refs are request-scoped only
{:ok, ref} = Snakepit.ZeroCopy.from_nx(tensor)

# Use within the same request
result = Snakepit.execute("process_tensor", %{tensor: ref})

# Don't store refs in session state - they won't work
# BAD: SessionStore.put_program(session_id, "cached_tensor", ref)
```

---

## Quick Reference

| Resource Type | Scope | Lifetime | Cross-Process Safe |
|--------------|-------|----------|-------------------|
| Session IDs | Application | TTL-based | Yes |
| Session State | Session | Until deleted/expired | Yes (via SessionStore) |
| Python Adapter | Request | Single request | N/A |
| Module Cache | Python process | Worker lifetime | N/A |
| ZeroCopy Refs | Request | Single request | No |

---

## Related Guides

- [Configuration](configuration.md) - Session store configuration options
- [Worker Profiles](worker-profiles.md) - How workers manage state
- [Python Adapters](python-adapters.md) - Adapter lifecycle and patterns
- [Observability](observability.md) - Telemetry and monitoring
