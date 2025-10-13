# Spec: Distributed Session Registry

**Feature ID**: SNK-7.0-001  
**Priority**: P0 (Critical)  
**Status**: Design Phase  
**Target Release**: Snakepit v0.7.0  
**Estimated Effort**: 2-3 weeks  

---

## Executive Summary

The Distributed Session Registry enables Snakepit sessions to survive node failures and scale across multi-node BEAM clusters. This addresses the critical limitation where current ETS/DETS-based sessions are lost when nodes crash or restart.

**Key Benefits:**
- Sessions survive individual node failures
- Horizontal scaling across BEAM clusters  
- Zero-downtime deployments with session preservation
- Backward compatibility with existing single-node deployments

---

## Problem Statement

### Current Limitations

1. **Single Point of Failure**: Sessions stored in ETS/DETS on single node
2. **No Cluster Support**: Cannot share sessions across multiple BEAM nodes
3. **Data Loss on Crashes**: Node failure = all sessions lost
4. **Scaling Bottleneck**: All session operations hit single node

### Real-World Impact

```elixir
# Current failure scenario
Node A crashes → All sessions on Node A lost
↓
Client requests fail with "session not found"
↓  
Applications must handle session recreation
↓
Poor user experience, data loss
```

---

## Solution Architecture

### Design Principles

1. **Pluggable Architecture**: Behavior-based adapters for different backends
2. **Backward Compatibility**: Existing code works unchanged
3. **Gradual Migration**: Users opt-in to distributed mode
4. **BEAM-Native**: Leverage Erlang distribution, not external systems

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                        │
│  Snakepit.execute/2, Snakepit.execute_in_session/3        │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                SessionStore (Facade)                       │
│  • Routes to configured adapter                            │
│  • Maintains backward compatibility                        │
│  • Handles adapter failures gracefully                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────▼─────────────┐
        │   SessionStore.Adapter    │
        │      (Behavior)           │
        └─────────────┬─────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
┌───▼────┐    ┌──────▼──────┐    ┌────▼─────┐
│  ETS   │    │    Horde    │    │  Custom  │
│Adapter │    │   Adapter   │    │ Adapter  │
│(Default)│    │(Distributed)│    │(User)    │
└────────┘    └─────────────┘    └──────────┘
```

---

## Technical Specification

### 1. SessionStore.Adapter Behavior

```elixir
defmodule Snakepit.SessionStore.Adapter do
  @moduledoc """
  Behavior for session storage backends.
  
  Implementations:
  - `Snakepit.SessionStore.ETS` - Single-node (default)
  - `Snakepit.SessionStore.Horde` - Multi-node distributed
  - Custom user implementations
  """
  
  @type session_id :: String.t()
  @type session :: Snakepit.Bridge.Session.t()
  @type opts :: keyword()
  @type error :: term()
  
  @doc """
  Create a new session.
  
  ## Guarantees
  - MUST be idempotent (creating same session_id twice returns existing)
  - MUST persist metadata for recovery after node restart
  - SHOULD complete within 100ms for local operations
  
  ## Parameters
  - session_id: Unique identifier for the session
  - opts: Configuration options (ttl, metadata, etc.)
  
  ## Returns
  - {:ok, session} - Session created or already exists
  - {:error, reason} - Creation failed
  """
  @callback create_session(session_id, opts) :: {:ok, session} | {:error, error}
  
  @doc """
  Retrieve a session by ID.
  
  ## Guarantees  
  - MUST return {:error, :not_found} if session doesn't exist
  - MUST update last_accessed timestamp for TTL management
  - SHOULD complete within 10ms for local, 50ms for distributed
  
  ## Parameters
  - session_id: Session identifier to retrieve
  
  ## Returns
  - {:ok, session} - Session found and returned
  - {:error, :not_found} - Session does not exist
  - {:error, reason} - Retrieval failed
  """
  @callback get_session(session_id) :: {:ok, session} | {:error, :not_found | error}
  
  @doc """
  Update a session atomically.
  
  ## Guarantees
  - MUST use optimistic locking or compare-and-swap
  - MUST return {:error, :conflict} if concurrent modification detected
  - SHOULD retry internally (up to 3 attempts) before returning conflict
  
  ## Parameters
  - session_id: Session to update
  - update_fn: Function that transforms session state
  
  ## Returns
  - {:ok, updated_session} - Update successful
  - {:error, :not_found} - Session doesn't exist
  - {:error, :conflict} - Concurrent modification detected
  - {:error, reason} - Update failed
  """
  @callback update_session(session_id, (session -> session)) :: 
    {:ok, session} | {:error, :not_found | :conflict | error}
  
  @doc """
  Delete a session.
  
  ## Guarantees
  - MUST be idempotent (deleting non-existent session returns :ok)
  - MUST clean up all associated resources (programs, variables, etc.)
  - SHOULD complete within 100ms
  
  ## Parameters
  - session_id: Session to delete
  
  ## Returns
  - :ok - Deletion successful or session didn't exist
  - {:error, reason} - Deletion failed
  """
  @callback delete_session(session_id) :: :ok | {:error, error}
  
  @doc """
  List all active sessions.
  
  ## Performance Warning
  This operation can be expensive in distributed mode as it requires
  querying all nodes. Use sparingly and prefer direct lookups.
  
  ## Returns
  - [session_id] - List of all active session IDs
  """
  @callback list_sessions() :: [session_id]
  
  @doc """
  Check if a session exists (fast path).
  
  ## Performance
  Faster than get_session/1 because it doesn't fetch full metadata.
  Useful for existence checks without data access.
  
  ## Parameters
  - session_id: Session to check
  
  ## Returns
  - true - Session exists
  - false - Session does not exist
  """
  @callback session_exists?(session_id) :: boolean()
  
  @doc """
  Store program data in a session.
  
  ## Guarantees
  - MUST be atomic with session updates
  - SHOULD validate program_data structure
  - MUST handle concurrent access safely
  
  ## Parameters
  - session_id: Target session
  - program_id: Unique program identifier within session
  - program_data: Program state to store
  
  ## Returns
  - :ok - Storage successful
  - {:error, :not_found} - Session doesn't exist
  - {:error, reason} - Storage failed
  """
  @callback store_program(session_id, program_id :: String.t(), program_data :: map()) ::
    :ok | {:error, :not_found | error}
  
  @doc """
  Retrieve program data from a session.
  
  ## Parameters
  - session_id: Source session
  - program_id: Program identifier to retrieve
  
  ## Returns
  - {:ok, program_data} - Program found
  - {:error, :not_found} - Session or program doesn't exist
  - {:error, reason} - Retrieval failed
  """
  @callback get_program(session_id, program_id :: String.t()) ::
    {:ok, map()} | {:error, :not_found | error}
  
  @doc """
  Get adapter-specific statistics and health information.
  
  ## Returns
  Map containing:
  - :type - Adapter type (:ets, :horde, :custom)
  - :node_count - Number of participating nodes (1 for single-node)
  - :session_count - Total sessions managed by this adapter
  - :health - :healthy | :degraded | :unhealthy
  - :latency_ms - Average operation latency
  - Additional adapter-specific metrics
  """
  @callback get_stats() :: map()
end
```

### 2. SessionStore Facade (Updated)

```elixir
defmodule Snakepit.Bridge.SessionStore do
  @moduledoc """
  Facade for session storage operations.
  
  Delegates to configured adapter while maintaining backward compatibility
  and providing graceful error handling.
  """
  
  use GenServer
  require Logger
  
  # Public API (unchanged for backward compatibility)
  def create_session(session_id, opts \\ [])
  def get_session(session_id)  
  def update_session(session_id, update_fn)
  def delete_session(session_id)
  def list_sessions()
  def session_exists?(session_id)
  def store_program(session_id, program_id, program_data)
  def get_program(session_id, program_id)
  
  # New API for adapter management
  def get_adapter_stats()
  def switch_adapter(new_adapter, migration_opts \\ [])
  def health_check()
  
  # Private implementation
  defp adapter do
    Application.get_env(:snakepit, :session_adapter, Snakepit.SessionStore.ETS)
  end
  
  defp with_fallback(operation, fallback_fn \\ &default_fallback/2) do
    try do
      operation.()
    rescue
      error ->
        Logger.error("Session adapter error: #{inspect(error)}")
        fallback_fn.(error, operation)
    catch
      :exit, reason ->
        Logger.error("Session adapter exit: #{inspect(reason)}")
        fallback_fn.(reason, operation)
    end
  end
  
  defp default_fallback(error, _operation) do
    {:error, {:adapter_failure, error}}
  end
end
```

### 3. ETS Adapter (Refactored)

```elixir
defmodule Snakepit.SessionStore.ETS do
  @moduledoc """
  Single-node session storage using ETS + DETS.
  
  Optimized for:
  - Single BEAM node deployments
  - Development and testing
  - Maximum performance (local memory only)
  
  NOT suitable for:
  - Multi-node production clusters  
  - High availability requirements
  - Cross-node session sharing
  """
  
  @behaviour Snakepit.SessionStore.Adapter
  
  use GenServer
  require Logger
  
  @table_name :snakepit_sessions_ets
  @dets_file :snakepit_sessions_dets
  
  # Behavior implementation
  @impl true
  def create_session(session_id, opts) do
    GenServer.call(__MODULE__, {:create_session, session_id, opts})
  end
  
  @impl true  
  def get_session(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, {last_accessed, ttl, session}}] ->
        # Update access time
        touched = Snakepit.Bridge.Session.touch(session)
        :ets.insert(@table_name, {session_id, {touched.last_accessed, touched.ttl, touched}})
        {:ok, touched}
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def update_session(session_id, update_fn) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, {last_accessed, ttl, session}}] ->
        try do
          updated_session = update_fn.(session)
          :ets.insert(@table_name, {session_id, {last_accessed, ttl, updated_session}})
          {:ok, updated_session}
        rescue
          error ->
            {:error, {:update_failed, error}}
        end
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def delete_session(session_id) do
    :ets.delete(@table_name, session_id)
    :dets.delete(@dets_file, session_id)
    :ok
  end
  
  @impl true
  def list_sessions() do
    :ets.select(@table_name, [{{:"$1", :_}, [], [:"$1"]}])
  end
  
  @impl true
  def session_exists?(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, _}] -> true
      [] -> false
    end
  end
  
  @impl true
  def store_program(session_id, program_id, program_data) do
    update_session(session_id, fn session ->
      Snakepit.Bridge.Session.put_program(session, program_id, program_data)
    end)
    |> case do
      {:ok, _session} -> :ok
      error -> error
    end
  end
  
  @impl true
  def get_program(session_id, program_id) do
    case get_session(session_id) do
      {:ok, session} ->
        Snakepit.Bridge.Session.get_program(session, program_id)
      error ->
        error
    end
  end
  
  @impl true
  def get_stats() do
    session_count = :ets.info(@table_name, :size) || 0
    memory_usage = :ets.info(@table_name, :memory) || 0
    
    %{
      type: :ets,
      node_count: 1,
      session_count: session_count,
      memory_usage_words: memory_usage,
      health: :healthy,
      latency_ms: 0.1  # ETS is very fast
    }
  end
  
  # GenServer implementation (existing code...)
end
```

### 4. Horde Adapter (New)

```elixir
defmodule Snakepit.SessionStore.Horde do
  @moduledoc """
  Distributed session storage using Horde.
  
  ## Setup
  Add to your application supervision tree:
  
      children = [
        {Horde.Registry, [name: Snakepit.SessionRegistry, keys: :unique]},
        {Horde.DynamicSupervisor, [name: Snakepit.SessionSupervisor, strategy: :one_for_one]},
        # ... your other children
      ]
  
  Configure Snakepit:
  
      config :snakepit,
        session_adapter: Snakepit.SessionStore.Horde,
        horde_registry: Snakepit.SessionRegistry,
        horde_supervisor: Snakepit.SessionSupervisor
  
  ## How It Works
  1. Sessions are GenServer processes supervised by Horde.DynamicSupervisor
  2. Horde automatically distributes processes across cluster nodes
  3. On node failure, Horde restarts processes on surviving nodes
  4. Session state is in-memory (Horde handles persistence via replication)
  
  ## Limitations
  - Requires 3+ nodes for optimal fault tolerance
  - Network partitions can cause temporary inconsistency
  - Higher latency than ETS (~5-10ms vs <1ms)
  - Requires Horde dependency
  """
  
  @behaviour Snakepit.SessionStore.Adapter
  
  require Logger
  
  # Each session is a GenServer that holds its state
  defmodule SessionProcess do
    use GenServer
    
    def start_link({session_id, opts}) do
      GenServer.start_link(__MODULE__, {session_id, opts}, name: via_tuple(session_id))
    end
    
    defp via_tuple(session_id) do
      registry = Application.get_env(:snakepit, :horde_registry)
      {:via, Horde.Registry, {registry, session_id}}
    end
    
    @impl true
    def init({session_id, opts}) do
      session = Snakepit.Bridge.Session.new(session_id, opts)
      
      # Schedule TTL cleanup if configured
      if session.ttl > 0 do
        Process.send_after(self(), :ttl_check, session.ttl * 1000)
      end
      
      {:ok, session}
    end
    
    @impl true
    def handle_call(:get, _from, session) do
      touched = Snakepit.Bridge.Session.touch(session)
      {:reply, {:ok, touched}, touched}
    end
    
    @impl true
    def handle_call({:update, update_fn}, _from, session) do
      try do
        updated = update_fn.(session)
        {:reply, {:ok, updated}, updated}
      rescue
        error ->
          {:reply, {:error, {:update_failed, error}}, session}
      end
    end
    
    @impl true
    def handle_call({:store_program, program_id, program_data}, _from, session) do
      updated = Snakepit.Bridge.Session.put_program(session, program_id, program_data)
      {:reply, :ok, updated}
    end
    
    @impl true
    def handle_call({:get_program, program_id}, _from, session) do
      result = Snakepit.Bridge.Session.get_program(session, program_id)
      {:reply, result, session}
    end
    
    @impl true
    def handle_info(:ttl_check, session) do
      if Snakepit.Bridge.Session.expired?(session) do
        Logger.info("Session #{session.id} expired, stopping")
        {:stop, :normal, session}
      else
        # Schedule next check
        Process.send_after(self(), :ttl_check, session.ttl * 1000)
        {:noreply, session}
      end
    end
  end
  
  # Adapter implementation
  @impl true
  def create_session(session_id, opts) do
    supervisor = Application.get_env(:snakepit, :horde_supervisor)
    
    child_spec = %{
      id: session_id,
      start: {SessionProcess, :start_link, [{session_id, opts}]},
      restart: :transient
    }
    
    case Horde.DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, _pid} ->
        get_session(session_id)
      
      {:error, {:already_started, _pid}} ->
        # Idempotent - session already exists
        get_session(session_id)
      
      error ->
        error
    end
  end
  
  @impl true
  def get_session(session_id) do
    registry = Application.get_env(:snakepit, :horde_registry)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, :get)
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def update_session(session_id, update_fn) do
    registry = Application.get_env(:snakepit, :horde_registry)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:update, update_fn})
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def delete_session(session_id) do
    registry = Application.get_env(:snakepit, :horde_registry)
    supervisor = Application.get_env(:snakepit, :horde_supervisor)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{pid, _}] ->
        Horde.DynamicSupervisor.terminate_child(supervisor, pid)
        :ok
      [] ->
        :ok  # Idempotent
    end
  end
  
  @impl true
  def list_sessions() do
    registry = Application.get_env(:snakepit, :horde_registry)
    Horde.Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
  
  @impl true
  def session_exists?(session_id) do
    registry = Application.get_env(:snakepit, :horde_registry)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end
  
  @impl true
  def store_program(session_id, program_id, program_data) do
    registry = Application.get_env(:snakepit, :horde_registry)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:store_program, program_id, program_data})
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def get_program(session_id, program_id) do
    registry = Application.get_env(:snakepit, :horde_registry)
    
    case Horde.Registry.lookup(registry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:get_program, program_id})
      [] ->
        {:error, :not_found}
    end
  end
  
  @impl true
  def get_stats() do
    registry = Application.get_env(:snakepit, :horde_registry)
    supervisor = Application.get_env(:snakepit, :horde_supervisor)
    
    # Get cluster information
    nodes = [node() | Node.list()]
    session_count = length(list_sessions())
    
    # Check Horde health
    health = case Horde.Registry.meta(registry, :members) do
      {:ok, members} when length(members) > 0 -> :healthy
      _ -> :degraded
    end
    
    %{
      type: :horde,
      node_count: length(nodes),
      session_count: session_count,
      health: health,
      latency_ms: 5.0,  # Typical distributed latency
      cluster_nodes: nodes,
      horde_members: Horde.Registry.meta(registry, :members)
    }
  end
end
```

---

## Configuration & Migration

### 1. Configuration Options

```elixir
# config/config.exs

# Single-node (default, backward compatible)
config :snakepit,
  session_adapter: Snakepit.SessionStore.ETS

# Distributed with Horde
config :snakepit,
  session_adapter: Snakepit.SessionStore.Horde,
  horde_registry: MyApp.SessionRegistry,
  horde_supervisor: MyApp.SessionSupervisor

# Custom adapter
config :snakepit,
  session_adapter: MyApp.CustomSessionAdapter,
  custom_adapter_opts: [
    redis_url: "redis://localhost:6379",
    pool_size: 10
  ]
```

### 2. Application Setup for Horde

```elixir
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Horde cluster components (if using distributed sessions)
      {Horde.Registry, [name: MyApp.SessionRegistry, keys: :unique]},
      {Horde.DynamicSupervisor, [name: MyApp.SessionSupervisor, strategy: :one_for_one]},
      
      # Snakepit components
      Snakepit.Application,
      
      # Your application components
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 3. Migration Utilities

```elixir
defmodule Snakepit.SessionStore.Migrator do
  @moduledoc """
  Utilities for migrating sessions between adapters.
  """
  
  @doc """
  Migrate all sessions from one adapter to another.
  
  ## Example
      # Migrate from ETS to Horde
      Migrator.migrate_sessions(
        from: Snakepit.SessionStore.ETS,
        to: Snakepit.SessionStore.Horde,
        batch_size: 100
      )
  """
  def migrate_sessions(opts) do
    from_adapter = Keyword.fetch!(opts, :from)
    to_adapter = Keyword.fetch!(opts, :to)
    batch_size = Keyword.get(opts, :batch_size, 50)
    
    session_ids = from_adapter.list_sessions()
    
    Logger.info("Migrating #{length(session_ids)} sessions from #{from_adapter} to #{to_adapter}")
    
    session_ids
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      Logger.info("Processing batch #{index + 1}/#{ceil(length(session_ids) / batch_size)}")
      migrate_batch(batch, from_adapter, to_adapter)
    end)
    
    Logger.info("Migration completed successfully")
  end
  
  defp migrate_batch(session_ids, from_adapter, to_adapter) do
    Enum.each(session_ids, fn session_id ->
      case from_adapter.get_session(session_id) do
        {:ok, session} ->
          case to_adapter.create_session(session_id, session: session) do
            {:ok, _} ->
              Logger.debug("Migrated session #{session_id}")
            {:error, reason} ->
              Logger.error("Failed to migrate session #{session_id}: #{inspect(reason)}")
          end
        
        {:error, :not_found} ->
          Logger.warn("Session #{session_id} not found during migration")
        
        {:error, reason} ->
          Logger.error("Failed to read session #{session_id}: #{inspect(reason)}")
      end
    end)
  end
  
  @doc """
  Validate that all sessions migrated correctly.
  """
  def validate_migration(from_adapter, to_adapter) do
    from_sessions = from_adapter.list_sessions()
    to_sessions = to_adapter.list_sessions()
    
    missing = from_sessions -- to_sessions
    extra = to_sessions -- from_sessions
    
    %{
      total_source: length(from_sessions),
      total_target: length(to_sessions),
      missing_sessions: missing,
      extra_sessions: extra,
      migration_complete: missing == [] and extra == []
    }
  end
end
```

---

## Testing Strategy

### 1. Unit Tests

```elixir
defmodule Snakepit.SessionStore.AdapterTest do
  use ExUnit.Case
  
  # Test all adapters with the same test suite
  for adapter <- [Snakepit.SessionStore.ETS, Snakepit.SessionStore.Horde] do
    describe "#{adapter}" do
      setup do
        # Setup adapter-specific test environment
        {:ok, adapter: unquote(adapter)}
      end
      
      test "create_session/2 creates new session", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        assert {:ok, session} = adapter.create_session(session_id, [])
        assert session.id == session_id
      end
      
      test "create_session/2 is idempotent", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        assert {:ok, session1} = adapter.create_session(session_id, [])
        assert {:ok, session2} = adapter.create_session(session_id, [])
        
        assert session1.id == session2.id
      end
      
      test "get_session/1 returns existing session", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        {:ok, _} = adapter.create_session(session_id, [])
        assert {:ok, session} = adapter.get_session(session_id)
        assert session.id == session_id
      end
      
      test "get_session/1 returns not_found for missing session", %{adapter: adapter} do
        assert {:error, :not_found} = adapter.get_session("nonexistent")
      end
      
      test "update_session/2 modifies session state", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        {:ok, _} = adapter.create_session(session_id, [])
        
        update_fn = fn session ->
          %{session | metadata: Map.put(session.metadata, :updated, true)}
        end
        
        assert {:ok, updated} = adapter.update_session(session_id, update_fn)
        assert updated.metadata.updated == true
      end
      
      test "delete_session/1 removes session", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        {:ok, _} = adapter.create_session(session_id, [])
        assert :ok = adapter.delete_session(session_id)
        assert {:error, :not_found} = adapter.get_session(session_id)
      end
      
      test "session_exists?/1 checks existence", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        
        refute adapter.session_exists?(session_id)
        
        {:ok, _} = adapter.create_session(session_id, [])
        assert adapter.session_exists?(session_id)
        
        adapter.delete_session(session_id)
        refute adapter.session_exists?(session_id)
      end
      
      test "store_program/3 and get_program/2 work correctly", %{adapter: adapter} do
        session_id = "test_session_#{System.unique_integer()}"
        program_id = "test_program"
        program_data = %{code: "print('hello')", variables: %{}}
        
        {:ok, _} = adapter.create_session(session_id, [])
        
        assert :ok = adapter.store_program(session_id, program_id, program_data)
        assert {:ok, ^program_data} = adapter.get_program(session_id, program_id)
      end
      
      test "get_stats/0 returns adapter information", %{adapter: adapter} do
        stats = adapter.get_stats()
        
        assert is_map(stats)
        assert Map.has_key?(stats, :type)
        assert Map.has_key?(stats, :session_count)
        assert Map.has_key?(stats, :health)
      end
    end
  end
end
```

### 2. Integration Tests

```elixir
defmodule Snakepit.SessionStore.IntegrationTest do
  use ExUnit.Case
  
  @moduletag :integration
  
  describe "adapter switching" do
    test "can switch from ETS to Horde with migration" do
      # Start with ETS
      Application.put_env(:snakepit, :session_adapter, Snakepit.SessionStore.ETS)
      
      # Create some sessions
      session_ids = for i <- 1..10, do: "session_#{i}"
      
      Enum.each(session_ids, fn session_id ->
        {:ok, _} = Snakepit.Bridge.SessionStore.create_session(session_id, [])
      end)
      
      # Verify sessions exist
      assert length(Snakepit.Bridge.SessionStore.list_sessions()) == 10
      
      # Switch to Horde
      Application.put_env(:snakepit, :session_adapter, Snakepit.SessionStore.Horde)
      
      # Migrate sessions
      Snakepit.SessionStore.Migrator.migrate_sessions(
        from: Snakepit.SessionStore.ETS,
        to: Snakepit.SessionStore.Horde
      )
      
      # Verify migration
      validation = Snakepit.SessionStore.Migrator.validate_migration(
        Snakepit.SessionStore.ETS,
        Snakepit.SessionStore.Horde
      )
      
      assert validation.migration_complete
      assert validation.total_target == 10
    end
  end
  
  describe "distributed session behavior" do
    @tag :cluster
    test "sessions survive node failures" do
      # This test requires a multi-node setup
      # Implementation would use LocalCluster or similar
      
      # 1. Start 3-node cluster with Horde
      # 2. Create sessions distributed across nodes
      # 3. Kill one node
      # 4. Verify sessions are still accessible from remaining nodes
      # 5. Verify Horde rebalanced sessions
    end
  end
end
```

### 3. Property-Based Tests

```elixir
defmodule Snakepit.SessionStore.PropertyTest do
  use ExUnit.Case
  use PropCheck
  
  property "session operations are consistent across adapters" do
    forall {adapter, operations} <- {adapter_gen(), operation_list_gen()} do
      # Execute same operations on different adapters
      results_ets = execute_operations(Snakepit.SessionStore.ETS, operations)
      results_horde = execute_operations(Snakepit.SessionStore.Horde, operations)
      
      # Results should be equivalent (ignoring timing differences)
      normalize_results(results_ets) == normalize_results(results_horde)
    end
  end
  
  defp adapter_gen do
    oneof([
      Snakepit.SessionStore.ETS,
      Snakepit.SessionStore.Horde
    ])
  end
  
  defp operation_list_gen do
    list(oneof([
      {:create_session, session_id_gen(), opts_gen()},
      {:get_session, session_id_gen()},
      {:delete_session, session_id_gen()},
      {:update_session, session_id_gen(), update_fn_gen()}
    ]))
  end
end
```

---

## Performance Considerations

### 1. Latency Expectations

| Operation | ETS Adapter | Horde Adapter | Notes |
|-----------|-------------|---------------|-------|
| create_session | <1ms | 5-10ms | Horde requires network coordination |
| get_session | <0.1ms | 1-5ms | Local lookup vs distributed lookup |
| update_session | <1ms | 5-15ms | Depends on network and contention |
| delete_session | <1ms | 5-10ms | Cleanup across nodes |
| list_sessions | 1-5ms | 10-50ms | Scales with cluster size |

### 2. Memory Usage

```elixir
# ETS Adapter
# Memory = (session_count * avg_session_size) + ETS overhead
# Typical: ~1KB per session + 10% overhead

# Horde Adapter  
# Memory = (sessions_on_node * avg_session_size) + Horde overhead
# Distributed across cluster, ~2x overhead for replication
```

### 3. Scalability Limits

```elixir
# ETS Adapter
# Max sessions: Limited by single-node memory (~1M sessions on 8GB)
# Max throughput: ~100K ops/sec (memory bound)

# Horde Adapter
# Max sessions: Limited by cluster memory (scales horizontally)
# Max throughput: ~10K ops/sec per node (network bound)
# Recommended: 3-10 nodes for optimal performance
```

---

## Monitoring & Observability

### 1. Telemetry Events

```elixir
# Session lifecycle events
[:snakepit, :session, :created]
# Measurements: %{duration_ms: float()}
# Metadata: %{session_id: string(), adapter: atom(), node: atom()}

[:snakepit, :session, :accessed]
# Measurements: %{duration_ms: float()}
# Metadata: %{session_id: string(), adapter: atom(), cache_hit: boolean()}

[:snakepit, :session, :updated]
# Measurements: %{duration_ms: float()}
# Metadata: %{session_id: string(), adapter: atom(), retry_count: integer()}

[:snakepit, :session, :deleted]
# Measurements: %{duration_ms: float()}
# Metadata: %{session_id: string(), adapter: atom(), reason: atom()}

# Adapter-specific events
[:snakepit, :session_adapter, :operation]
# Measurements: %{duration_ms: float(), queue_time_ms: float()}
# Metadata: %{adapter: atom(), operation: atom(), success: boolean()}

[:snakepit, :session_adapter, :error]
# Measurements: %{error_count: integer()}
# Metadata: %{adapter: atom(), error_type: atom(), recoverable: boolean()}

# Distributed events (Horde only)
[:snakepit, :horde, :rebalance]
# Measurements: %{sessions_moved: integer(), duration_ms: float()}
# Metadata: %{from_node: atom(), to_node: atom(), reason: atom()}

[:snakepit, :horde, :node_join]
# Measurements: %{cluster_size: integer()}
# Metadata: %{node: atom(), total_sessions: integer()}

[:snakepit, :horde, :node_leave]
# Measurements: %{cluster_size: integer(), sessions_affected: integer()}
# Metadata: %{node: atom(), reason: atom()}
```

### 2. Health Checks

```elixir
defmodule Snakepit.SessionStore.HealthCheck do
  @moduledoc """
  Health check endpoints for session storage.
  """
  
  def check_health do
    adapter = Application.get_env(:snakepit, :session_adapter)
    
    with {:ok, stats} <- safe_get_stats(adapter),
         :ok <- validate_adapter_health(stats) do
      {:ok, %{
        status: :healthy,
        adapter: adapter,
        stats: stats,
        timestamp: DateTime.utc_now()
      }}
    else
      {:error, reason} ->
        {:error, %{
          status: :unhealthy,
          adapter: adapter,
          reason: reason,
          timestamp: DateTime.utc_now()
        }}
    end
  end
  
  defp safe_get_stats(adapter) do
    try do
      {:ok, adapter.get_stats()}
    rescue
      error ->
        {:error, {:stats_failed, error}}
    catch
      :exit, reason ->
        {:error, {:stats_exit, reason}}
    end
  end
  
  defp validate_adapter_health(stats) do
    cond do
      stats.health == :unhealthy ->
        {:error, :adapter_unhealthy}
      
      stats.latency_ms > 1000 ->
        {:error, :high_latency}
      
      Map.get(stats, :error_rate, 0) > 0.1 ->
        {:error, :high_error_rate}
      
      true ->
        :ok
    end
  end
end
```

### 3. Metrics Dashboard

```elixir
defmodule SnakepitWeb.SessionMetricsLive do
  use Phoenix.LiveView
  
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :update_metrics)
    end
    
    {:ok, assign(socket, :metrics, get_current_metrics())}
  end
  
  def handle_info(:update_metrics, socket) do
    {:noreply, assign(socket, :metrics, get_current_metrics())}
  end
  
  def render(assigns) do
    ~H"""
    <div class="session-metrics">
      <h2>Session Store Metrics</h2>
      
      <div class="adapter-info">
        <h3>Adapter: <%= @metrics.adapter %></h3>
        <div class="health-status" class={health_class(@metrics.health)}>
          Status: <%= @metrics.health %>
        </div>
      </div>
      
      <div class="metrics-grid">
        <div class="metric">
          <h4>Total Sessions</h4>
          <span class="value"><%= @metrics.session_count %></span>
        </div>
        
        <div class="metric">
          <h4>Average Latency</h4>
          <span class="value"><%= @metrics.latency_ms %>ms</span>
        </div>
        
        <div class="metric">
          <h4>Cluster Nodes</h4>
          <span class="value"><%= @metrics.node_count %></span>
        </div>
        
        <div class="metric">
          <h4>Operations/sec</h4>
          <span class="value"><%= @metrics.ops_per_sec %></span>
        </div>
      </div>
      
      <%= if @metrics.adapter == Snakepit.SessionStore.Horde do %>
        <div class="horde-specific">
          <h3>Cluster Information</h3>
          <ul>
            <%= for node <- @metrics.cluster_nodes do %>
              <li><%= node %></li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </div>
    """
  end
  
  defp get_current_metrics do
    adapter = Application.get_env(:snakepit, :session_adapter)
    stats = adapter.get_stats()
    
    %{
      adapter: adapter,
      health: stats.health,
      session_count: stats.session_count,
      latency_ms: stats.latency_ms,
      node_count: stats.node_count,
      cluster_nodes: Map.get(stats, :cluster_nodes, [node()]),
      ops_per_sec: calculate_ops_per_sec()
    }
  end
end
```

---

## Deployment Guide

### 1. Single-Node to Distributed Migration

```bash
# Step 1: Prepare Horde infrastructure
# Add Horde to mix.exs
{:horde, "~> 0.9.0"}

# Step 2: Update application supervision tree
# Add Horde components to children list

# Step 3: Deploy with ETS adapter (no downtime)
# Existing sessions continue working

# Step 4: Run migration script
mix run -e "
  Snakepit.SessionStore.Migrator.migrate_sessions(
    from: Snakepit.SessionStore.ETS,
    to: Snakepit.SessionStore.Horde
  )
"

# Step 5: Switch configuration
# Update config to use Horde adapter

# Step 6: Deploy new configuration
# Sessions now distributed across cluster
```

### 2. Kubernetes Deployment

```yaml
# k8s/snakepit-deployment.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: snakepit-cluster
spec:
  serviceName: snakepit-cluster
  replicas: 3
  selector:
    matchLabels:
      app: snakepit
  template:
    metadata:
      labels:
        app: snakepit
    spec:
      containers:
      - name: snakepit
        image: myapp/snakepit:latest
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          value: "snakepit@$(POD_IP)"
        - name: CLUSTER_STRATEGY
          value: "kubernetes"
        - name: KUBERNETES_SELECTOR
          value: "app=snakepit"
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: SESSION_ADAPTER
          value: "Snakepit.SessionStore.Horde"
        ports:
        - containerPort: 4000
          name: http
        - containerPort: 4369
          name: epmd
        - containerPort: 9000-9100
          name: dist
        livenessProbe:
          httpGet:
            path: /health/sessions
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready/sessions
            port: 4000
          initialDelaySeconds: 10
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: snakepit-cluster
spec:
  clusterIP: None  # Headless service for Horde
  selector:
    app: snakepit
  ports:
  - port: 4369
    name: epmd
  - port: 4000
    name: http
```

### 3. Docker Compose (Development)

```yaml
# docker-compose.yml
version: '3.8'

services:
  snakepit-1:
    build: .
    hostname: snakepit-1
    environment:
      - NODE_NAME=snakepit@snakepit-1
      - COOKIE=secret_cookie
      - SESSION_ADAPTER=Snakepit.SessionStore.Horde
      - CLUSTER_NODES=snakepit@snakepit-1,snakepit@snakepit-2,snakepit@snakepit-3
    ports:
      - "4000:4000"
    networks:
      - snakepit-cluster

  snakepit-2:
    build: .
    hostname: snakepit-2
    environment:
      - NODE_NAME=snakepit@snakepit-2
      - COOKIE=secret_cookie
      - SESSION_ADAPTER=Snakepit.SessionStore.Horde
      - CLUSTER_NODES=snakepit@snakepit-1,snakepit@snakepit-2,snakepit@snakepit-3
    ports:
      - "4001:4000"
    networks:
      - snakepit-cluster

  snakepit-3:
    build: .
    hostname: snakepit-3
    environment:
      - NODE_NAME=snakepit@snakepit-3
      - COOKIE=secret_cookie
      - SESSION_ADAPTER=Snakepit.SessionStore.Horde
      - CLUSTER_NODES=snakepit@snakepit-1,snakepit@snakepit-2,snakepit@snakepit-3
    ports:
      - "4002:4000"
    networks:
      - snakepit-cluster

networks:
  snakepit-cluster:
    driver: bridge
```

---

## Risk Assessment & Mitigation

### 1. Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Horde dependency issues | Medium | High | Thorough testing, fallback to ETS |
| Network partition handling | Medium | Medium | Document split-brain scenarios |
| Performance regression | Low | Medium | Comprehensive benchmarking |
| Migration data loss | Low | High | Extensive testing, validation tools |

### 2. Operational Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Complex deployment | Medium | Medium | Detailed documentation, automation |
| Monitoring gaps | Medium | Medium | Comprehensive telemetry |
| Support burden | Medium | Low | Clear adapter selection guide |

### 3. Mitigation Strategies

1. **Gradual Rollout**: ETS → Horde migration path
2. **Extensive Testing**: Unit, integration, property-based tests
3. **Monitoring**: Comprehensive telemetry and health checks
4. **Documentation**: Clear setup and troubleshooting guides
5. **Fallback Plan**: Always possible to revert to ETS adapter

---

## Success Criteria

### 1. Functional Requirements ✅

- [ ] Sessions survive node failures (Horde adapter)
- [ ] Backward compatibility maintained (ETS adapter default)
- [ ] Zero-downtime migration path (ETS → Horde)
- [ ] Consistent API across all adapters
- [ ] Comprehensive test coverage (>95%)

### 2. Performance Requirements ✅

- [ ] ETS adapter: <1ms average latency
- [ ] Horde adapter: <10ms average latency
- [ ] Support 10,000+ concurrent sessions per node
- [ ] Memory usage scales linearly with session count
- [ ] No memory leaks during long-running tests

### 3. Operational Requirements ✅

- [ ] Health check endpoints available
- [ ] Telemetry events for all operations
- [ ] Migration tools and validation
- [ ] Comprehensive documentation
- [ ] Kubernetes deployment examples

---

## Implementation Checklist

### Phase 1: Foundation (Week 1)
- [ ] Define `SessionStore.Adapter` behavior
- [ ] Refactor existing `SessionStore` to use adapter pattern
- [ ] Extract `ETS` adapter from current implementation
- [ ] Create adapter configuration system
- [ ] Write unit tests for behavior compliance

### Phase 2: Horde Implementation (Week 2)
- [ ] Implement `Horde` adapter with `SessionProcess`
- [ ] Add Horde dependency (optional)
- [ ] Create cluster setup documentation
- [ ] Write Horde-specific tests
- [ ] Performance benchmarking

### Phase 3: Migration & Tooling (Week 3)
- [ ] Build migration utilities
- [ ] Create health check system
- [ ] Add telemetry events
- [ ] Write integration tests
- [ ] Create deployment guides

### Phase 4: Documentation & Polish (Week 4)
- [ ] Comprehensive documentation
- [ ] Example applications
- [ ] Performance optimization
- [ ] Final testing and validation
- [ ] Release preparation

---

## Conclusion

The Distributed Session Registry transforms Snakepit from a single-node Python bridge into a truly distributed, production-ready external language orchestration platform. By implementing a pluggable adapter architecture, we maintain backward compatibility while enabling advanced distributed deployments.

This feature directly addresses the critical feedback about distributed systems and positions Snakepit as the premier solution for external language integration in the BEAM ecosystem.

**Next Steps:**
1. Review and approve this specification
2. Begin Phase 1 implementation
3. Set up CI/CD for multi-node testing
4. Create example applications demonstrating distributed capabilities

---

**Document Metadata:**
- **Created**: 2025-10-12
- **Author**: Kiro AI Assistant  
- **Reviewers**: [To be assigned]
- **Status**: Draft → Review → Approved → Implementation
- **Related Issues**: [To be created]
- **Dependencies**: Horde library, Erlang distribution