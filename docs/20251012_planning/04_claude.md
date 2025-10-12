# Snakepit: Complete Guide to Distribution-Ready Architecture

## Executive Summary

You're right—the BEAM makes multi-node testing trivial. One WSL instance is **perfect** for development. This guide takes you from current single-node architecture to production-grade distributed Snakepit, focusing on **practical implementation** over theory.

**Timeline Estimate:** 2-3 weeks full-time, assuming you know CAP/CRDTs conceptually.

---

## Part 1: Current Architecture Analysis

### What You Have (Single-Node)

```
┌─────────────────────────────────────────┐
│ BEAM Node (snakepit@localhost)          │
│                                          │
│  ┌──────────────┐    ┌────────────────┐ │
│  │ SessionStore │◄───┤ ETS (volatile) │ │
│  │   (GenServer)│    └────────────────┘ │
│  └──────┬───────┘    ┌────────────────┐ │
│         │            │ DETS (persist) │ │
│         └───────────►└────────────────┘ │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ Pool (100 workers)               │   │
│  │  ├─ GRPCWorker → Python PID 1234 │   │
│  │  ├─ GRPCWorker → Python PID 1235 │   │
│  │  └─ GRPCWorker → Python PID 1236 │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Critical Failure Modes:**

1. **Node dies → All sessions lost** (DETS only persists to disk, not replicated)
2. **Worker crashes → Session state inconsistent** (no distributed locking)
3. **Scale-out impossible** (ETS doesn't replicate across nodes)

---

## Part 2: Target Architecture (Distributed)

```
┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐
│ Node A (snakepit@node_a) │  │ Node B (snakepit@node_b) │  │ Node C (snakepit@node_c) │
│                          │  │                          │  │                          │
│ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │
│ │ Horde.Registry       │◄┼──┼►│ Horde.Registry       │◄┼──┼►│ Horde.Registry       │ │
│ │ (Session Metadata)   │ │  │ │ (Session Metadata)   │ │  │ │ (Session Metadata)   │ │
│ └──────────────────────┘ │  │ └──────────────────────┘ │  │ └──────────────────────┘ │
│                          │  │                          │  │                          │
│ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │
│ │ Horde.DynamicSuperv. │◄┼──┼►│ Horde.DynamicSuperv. │◄┼──┼►│ Horde.DynamicSuperv. │ │
│ │ (Session Processes)  │ │  │ │ (Session Processes)  │ │  │ │ (Session Processes)  │ │
│ └──────────────────────┘ │  │ └──────────────────────┘ │  │ └──────────────────────┘ │
│                          │  │                          │  │                          │
│ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │  │ ┌──────────────────────┐ │
│ │ Pool (50 workers)    │ │  │ │ Pool (50 workers)    │ │  │ │ Pool (50 workers)    │ │
│ │  ├─ Worker → Py 1001 │ │  │ │  ├─ Worker → Py 2001 │ │  │ │  ├─ Worker → Py 3001 │ │
│ │  └─ Worker → Py 1002 │ │  │ │  └─ Worker → Py 2002 │ │  │ │  └─ Worker → Py 3002 │ │
│ └──────────────────────┘ │  │ └──────────────────────┘ │  │ └──────────────────────┘ │
└──────────────────────────┘  └──────────────────────────┘  └──────────────────────────┘
          ▲                              ▲                              ▲
          └──────────────────────────────┼──────────────────────────────┘
                          Erlang Distribution Protocol
                          (Magic Mesh Networking)
```

**Key Properties:**

✅ **Any node can handle any request** (location transparency)  
✅ **Sessions survive node failures** (Horde replicates state)  
✅ **Workers pinned to nodes** (Python processes are local)  
✅ **Automatic rebalancing** (Horde moves sessions on node join/leave)

---

## Part 3: Step-by-Step Migration Plan

### Phase 1: Make SessionStore Distribution-Ready (Week 1)

#### Step 1.1: Define the Adapter Behaviour

**File:** `lib/snakepit/session_store/adapter.ex`

```elixir
defmodule Snakepit.SessionStore.Adapter do
  @moduledoc """
  Behaviour for session storage backends.
  
  Implementations:
  - `Snakepit.SessionStore.ETS` - Single-node (current, default)
  - `Snakepit.SessionStore.Horde` - Multi-node (user provides)
  
  ## Why a Behaviour?
  
  Snakepit ships with single-node support. Users opt into distributed
  mode by adding Horde dependency and configuring:
  
      config :snakepit, session_adapter: MyApp.SessionStore.Horde
  
  This avoids forcing Horde dependency on 90% of users who don't need it.
  """
  
  @type session_id :: String.t()
  @type session :: Snakepit.Bridge.Session.t()
  @type opts :: keyword()
  
  @doc """
  Create a new session.
  
  ## Guarantees
  
  - MUST be idempotent (creating same session_id twice returns existing session)
  - MUST persist metadata (user can retrieve after node restart in distributed mode)
  - MAY return `{:error, :already_exists}` if strict mode enabled
  """
  @callback create_session(session_id, opts) :: {:ok, session} | {:error, term()}
  
  @doc """
  Get a session by ID.
  
  ## Guarantees
  
  - MUST return `{:error, :not_found}` if session doesn't exist
  - SHOULD be fast (< 1ms for local lookups, < 10ms for distributed)
  - MUST update last_accessed timestamp (for TTL expiry)
  """
  @callback get_session(session_id) :: {:ok, session} | {:error, :not_found}
  
  @doc """
  Update a session atomically.
  
  ## Guarantees
  
  - MUST use optimistic locking (compare-and-swap or similar)
  - MUST return `{:error, :conflict}` if concurrent modification detected
  - SHOULD retry internally (up to 3 attempts) before returning conflict error
  
  ## Example
  
      update_session("session_123", fn session ->
        Session.put_program(session, "prog_1", %{data: "..."})
      end)
  """
  @callback update_session(session_id, (session -> session)) :: 
    {:ok, session} | {:error, term()}
  
  @doc """
  Delete a session.
  
  ## Guarantees
  
  - MUST be idempotent (deleting non-existent session returns :ok)
  - MUST clean up all associated resources (programs, tools, etc.)
  """
  @callback delete_session(session_id) :: :ok
  
  @doc """
  List all active sessions.
  
  ## Performance
  
  This can be slow in distributed mode (requires network round-trip to all nodes).
  Use sparingly, prefer direct lookups by session_id.
  """
  @callback list_sessions() :: [session_id]
  
  @doc """
  Check if a session exists (fast path, no metadata fetch).
  
  ## Performance
  
  Faster than get_session/1 because it doesn't need to fetch full metadata.
  """
  @callback session_exists?(session_id) :: boolean()
  
  @doc """
  Store program data in a session.
  
  ## Guarantees
  
  - MUST be atomic with session updates
  - SHOULD validate program_data structure
  """
  @callback store_program(session_id, program_id :: String.t(), program_data :: map()) ::
    :ok | {:error, term()}
  
  @doc """
  Retrieve program data from a session.
  """
  @callback get_program(session_id, program_id :: String.t()) ::
    {:ok, map()} | {:error, :not_found}
end
```

#### Step 1.2: Refactor Current Implementation

**File:** `lib/snakepit/session_store/ets.ex` (extract from current SessionStore)

```elixir
defmodule Snakepit.SessionStore.ETS do
  @moduledoc """
  Single-node session storage using ETS + DETS.
  
  This is the default adapter, optimized for:
  - Single BEAM node deployments
  - Development/testing
  - Maximum performance (local memory only)
  
  NOT suitable for:
  - Multi-node production clusters
  - High availability requirements
  """
  
  @behaviour Snakepit.SessionStore.Adapter
  
  use GenServer
  require Logger
  
  @table_name :snakepit_sessions_ets
  @dets_file :snakepit_sessions_dets
  
  # Keep all your current SessionStore implementation here
  # Just change from `def create_session` to implementing callbacks
  
  @impl true
  def create_session(session_id, opts) do
    # Your current implementation
    GenServer.call(__MODULE__, {:create_session, session_id, opts})
  end
  
  @impl true
  def get_session(session_id) do
    # Your current implementation with ETS lookup
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, {_last_accessed, _ttl, session}}] ->
        touched = Snakepit.Bridge.Session.touch(session)
        :ets.insert(@table_name, {session_id, {touched.last_accessed, touched.ttl, touched}})
        {:ok, touched}
      [] ->
        {:error, :not_found}
    end
  end
  
  # ... rest of current implementation
end
```

#### Step 1.3: Update SessionStore to Delegate

**File:** `lib/snakepit/bridge/session_store.ex` (modify existing)

```elixir
defmodule Snakepit.Bridge.SessionStore do
  @moduledoc """
  Facade for session storage operations.
  
  Delegates to configured adapter (ETS by default, Horde for distributed).
  """
  
  # Keep your current functions, but delegate:
  
  defp adapter do
    Application.get_env(:snakepit, :session_adapter, Snakepit.SessionStore.ETS)
  end
  
  def create_session(session_id, opts \\ []) do
    adapter().create_session(session_id, opts)
  end
  
  def get_session(session_id) do
    adapter().get_session(session_id)
  end
  
  # ... etc for all public functions
end
```

---

### Phase 2: Implement Horde Adapter (Week 1, Days 3-5)

#### Step 2.1: Add Horde Dependency

**File:** `mix.exs`

```elixir
defp deps do
  [
    # ... existing deps
    {:horde, "~> 0.9.0", optional: true}  # ← Make it optional!
  ]
end
```

**Why optional?** Most users don't need distributed mode. They shouldn't pay the dependency cost.

#### Step 2.2: Create Horde Adapter (Example Implementation)

**File:** `lib/snakepit/session_store/horde.ex`

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
  4. Session state is in-memory (no DETS - Horde handles persistence via replication)
  
  ## Limitations
  
  - Requires 3+ nodes for quorum (2 nodes = split-brain risk)
  - Network partitions can cause temporary inconsistency
  - Higher latency than ETS (~5-10ms vs <1ms)
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
    
    def init({session_id, opts}) do
      session = Snakepit.Bridge.Session.new(session_id, opts)
      {:ok, session}
    end
    
    def handle_call(:get, _from, session) do
      touched = Snakepit.Bridge.Session.touch(session)
      {:reply, {:ok, touched}, touched}
    end
    
    def handle_call({:update, update_fn}, _from, session) do
      updated = update_fn.(session)
      {:reply, {:ok, updated}, updated}
    end
    
    def handle_call({:store_program, program_id, program_data}, _from, session) do
      updated = Snakepit.Bridge.Session.put_program(session, program_id, program_data)
      {:reply, :ok, updated}
    end
    
    def handle_call({:get_program, program_id}, _from, session) do
      result = Snakepit.Bridge.Session.get_program(session, program_id)
      {:reply, result, session}
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
  def list_sessions do
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
end
```

---

### Phase 3: Distributed Pool Management (Week 2)

**Problem:** Workers are Python OS processes, can't migrate between nodes.

**Solution:** Location-aware routing + worker affinity.

#### Step 3.1: Add Node Metadata to Workers

**File:** `lib/snakepit/pool.ex` (modify worker registration)

```elixir
defmodule Snakepit.Pool do
  # When registering workers, include node information
  
  defp register_worker_with_metadata(worker_id, pid) do
    metadata = %{
      node: node(),  # ← Critical for routing
      worker_module: Snakepit.GRPCWorker,
      started_at: System.system_time(:second)
    }
    
    Registry.register(Snakepit.Pool.Registry, worker_id, metadata)
  end
end
```

#### Step 3.2: Implement Distributed Work Stealing

**File:** `lib/snakepit/pool/distributed.ex` (new)

```elixir
defmodule Snakepit.Pool.Distributed do
  @moduledoc """
  Distributed pool coordination using libring (consistent hashing).
  
  ## Strategy
  
  1. Each node maintains its own local pool of workers
  2. Requests are routed to nodes based on session_id (consistent hashing)
  3. If target node is down, request routes to next node in ring
  4. Workers never migrate (Python processes are local)
  
  ## Example
  
      # Request comes in with session_id = "session_123"
      # Hash determines Node B should handle it
      # Node A forwards request to Node B via RPC
      # Node B's local pool executes on local worker
  """
  
  require Logger
  
  @doc """
  Execute a command, routing to the correct node based on session affinity.
  """
  def execute(command, args, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    target_node = determine_target_node(session_id)
    
    if target_node == node() do
      # Local execution
      Snakepit.Pool.execute_local(command, args, opts)
    else
      # Remote execution via RPC
      Logger.debug("Routing request to #{target_node} for session #{session_id}")
      
      case :rpc.call(target_node, Snakepit.Pool, :execute_local, [command, args, opts]) do
        {:badrpc, reason} ->
          Logger.error("RPC failed to #{target_node}: #{inspect(reason)}")
          # Fallback to next node in ring
          execute_with_fallback(command, args, opts, [target_node])
        
        result ->
          result
      end
    end
  end
  
  defp determine_target_node(session_id) do
    # Use consistent hashing to determine which node should handle this session
    nodes = [node() | Node.list()]
    
    if length(nodes) == 1 do
      node()
    else
      hash = :erlang.phash2(session_id, length(nodes))
      Enum.at(nodes, hash)
    end
  end
  
  defp execute_with_fallback(command, args, opts, tried_nodes) do
    all_nodes = [node() | Node.list()]
    available_nodes = all_nodes -- tried_nodes
    
    case available_nodes do
      [] ->
        {:error, :no_available_nodes}
      
      [next_node | _] ->
        Logger.warning("Falling back to #{next_node}")
        
        case :rpc.call(next_node, Snakepit.Pool, :execute_local, [command, args, opts]) do
          {:badrpc, _} ->
            execute_with_fallback(command, args, opts, [next_node | tried_nodes])
          
          result ->
            result
        end
    end
  end
  
  defp generate_session_id do
    "session_#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
```

#### Step 3.3: Add Node Discovery

**File:** `lib/snakepit/cluster.ex` (new)

```elixir
defmodule Snakepit.Cluster do
  @moduledoc """
  Automatic cluster formation using libcluster.
  
  ## Configuration
  
      config :libcluster,
        topologies: [
          snakepit: [
            strategy: Cluster.Strategy.Epmd,
            config: [
              hosts: [
                :"snakepit@node_a",
                :"snakepit@node_b",
                :"snakepit@node_c"
              ]
            ]
          ]
        ]
  
  ## Alternative Strategies
  
  - Kubernetes: Use `Cluster.Strategy.Kubernetes` (DNS-based)
  - Consul: Use `Cluster.Strategy.Consul` (service discovery)
  - Local dev: Use `Cluster.Strategy.Gossip` (UDP multicast)
  """
  
  use GenServer
  require Logger
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Subscribe to node up/down events
    :net_kernel.monitor_nodes(true, node_type: :visible)
    
    {:ok, %{}}
  end
  
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("🟢 Node joined cluster: #{node}")
    
    # Rebalance workers if using Horde
    if horde_enabled?() do
      rebalance_sessions()
    end
    
    {:noreply, state}
  end
  
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("🔴 Node left cluster: #{node}")
    
    # Horde will automatically restart processes from dead node
    # No manual intervention needed
    
    {:noreply, state}
  end
  
  defp horde_enabled? do
    Application.get_env(:snakepit, :session_adapter) == Snakepit.SessionStore.Horde
  end
  
  defp rebalance_sessions do
    # Horde handles this automatically via delta-CRDT
    # Just log for observability
    Logger.info("Horde rebalancing sessions across cluster...")
  end
end
```

---

### Phase 4: Testing Infrastructure (Week 2, Days 4-7)

#### Step 4.1: Multi-Node Test Setup (One WSL Instance!)

**File:** `test/support/cluster_case.ex`

```elixir
defmodule Snakepit.ClusterCase do
  @moduledoc """
  Test case for multi-node scenarios.
  
  Starts 3 BEAM nodes in one OS process:
  - snakepit_test_a@127.0.0.1
  - snakepit_test_b@127.0.0.1
  - snakepit_test_c@127.0.0.1
  
  ## Usage
  
      defmodule Snakepit.DistributedTest do
        use Snakepit.ClusterCase
        
        test "sessions survive node failure", %{nodes: nodes} do
          [node_a, node_b, node_c] = nodes
          
          # Create session on node A
          session_id = create_session_on_node(node_a, "test_session")
          
          # Verify visible from node B
          assert session_exists_on_node?(node_b, session_id)
          
          # Kill node A
          stop_node(node_a)
          
          # Session should still be accessible on node B/C
          assert session_exists_on_node?(node_b, session_id)
        end
      end
  """
  
  use ExUnit.CaseTemplate
  
  using do
    quote do
      import Snakepit.ClusterCase
    end
  end
  
  setup do
    # Start 3 slave nodes
    nodes = start_cluster(3)
    
    on_exit(fn ->
      stop_cluster(nodes)
    end)
    
    {:ok, nodes: nodes}
  end
  
  def start_cluster(num_nodes) do
    # Ensure epmd is running
    {_, 0} = System.cmd("epmd", ["-daemon"])
    
    # Start slave nodes
    for n <- 1..num_nodes do
      node_name = :"snakepit_test_#{node_letter(n)}@127.0.0.1"
      
      {:ok, node} = :slave.start_link('127.0.0.1', node_short_name(n), '-setcookie test_cookie')
      
      # Load Snakepit application on slave node
      :rpc.call(node, Application, :ensure_all_started, [:snakepit])
      
      # Configure Horde on slave node
      if horde_enabled?() do
        configure_horde_on_node(node)
      end
      
      node
    end
  end
  
  defp node_letter(1), do: "a"
  defp node_letter(2), do: "b"
  defp node_letter(3), do: "c"
  
  defp node_short_name(n), do: :"snakepit_test_#{node_letter(n)}"
  
  def stop_cluster(nodes) do
    Enum.each(nodes, fn node ->
      :slave.stop(node)
    end)
  end
  
  def stop_node(node) do
    :slave.stop(node)
  end
  
  def create_session_on_node(node, session_id) do
    :rpc.call(node, Snakepit.Bridge.SessionStore, :create_session, [session_id, []])
    session_id
  end
  
  def session_exists_on_node?(node, session_id) do
    case :rpc.call(node, Snakepit.Bridge.SessionStore, :get_session, [session_id]) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end
  
  defp horde_enabled? do
    Application.get_env(:snakepit, :session_adapter) == Snakepit.SessionStore.Horde
  end
  
  defp configure_horde_on_node(node) do
    # Start Horde registry and supervisor on slave node
    :rpc.call(node, Horde.Registry, :start_link, [
      [name: Snakepit.SessionRegistry, keys: :unique]
    ])
    
    :rpc.call(node, Horde.DynamicSupervisor, :start_link, [
      [name: Snakepit.SessionSupervisor, strategy: :one_for_one]
    ])
    
    # Join Horde cluster
    members = Enum.map([node() | Node.list()], fn n ->
      {Snakepit.SessionRegistry, n}
    end)
    
    :rpc.call(node, Horde.Cluster, :set_members, [Snakepit.SessionRegistry, members])
  end
end
```

#### Step 4.2: Example Distributed Tests

**File:** `test/snakepit/distributed_test.exs`

```elixir
defmodule Snakepit.DistributedTest do
  use Snakepit.ClusterCase
  
  @moduletag :distributed
  
  describe "session replication" do
    test "sessions are visible across all nodes", %{nodes: nodes} do
      [node_a, node_b, node_c] = nodes
      
      # Create session on node A
      session_id = create_session_on_node(node_a, "replicated_session")
      
      # Should be visible on all nodes within 100ms (Horde propagation)
      Process.sleep(100)
      
      assert session_exists_on_node?(node_a, session_id)
      assert session_exists_on_node?(node_b, session_id)
      assert session_exists_on_node?(node_c, session_id)
    end
    
    test "sessions survive single node failure", %{nodes: nodes} do
      [node_a, node_b, node_c] = nodes
      
      # Create 10 sessions distributed across nodes
      session_ids = for n <- 1..10 do
        session_id = "session_#{n}"
        create_session_on_node(Enum.random(nodes), session_id)
        session_id
      end
      
      # Kill node A
      stop_node(node_a)
      
      # Wait for Horde to detect failure and rebalance
      Process.sleep(500)
      
      # All sessions should still be accessible from remaining nodes
      Enum.each(session_ids, fn session_id ->
        assert session_exists_on_node?(node_b, session_id) or
               session_exists_on_node?(node_c, session_id),
               "Session #{session_id} lost after node failure!"
      end)
    end
  end
  
  describe "distributed work routing" do
    test "requests route to correct node based on session affinity", %{nodes: nodes} do
      [node_a, node_b, _node_c] = nodes
      
      # Create session on node B
      session_id = create_session_on_node(node_b, "sticky_session")
      
      # Execute command from node A with session affinity
      result = :rpc.call(node_a, Snakepit.Pool.Distributed, :execute, [
        "ping",
        %{message: "test"},
        [session_id: session_id]
      ])
      
      # Should succeed (routed to node B)
      assert {:ok, _} = result
    end
  end
  
  describe "split-brain scenarios" do
    test "network partition recovery", %{nodes: nodes} do
      [node_a, node_b, node_c] = nodes
      
      # Create sessions on all nodes
      session_a = create_session_on_node(node_a, "session_a")
      session_b = create_session_on_node(node_b, "session_b")
      session_c = create_session_on_node(node_c, "session_c")
      
      # Simulate network partition: disconnect node A
      :rpc.call(node_a, :erlang, :disconnect_node, [node_b])
      :rpc.call(node_a, :erlang, :disconnect_node, [node_c])
      
      # Wait for partition to take effect
      Process.sleep(1000)
      
      # Reconnect
      :rpc.call(node_a, :net_kernel, :connect_node, [node_b])
      :rpc.call(node_a, :net_kernel, :connect_node, [node_c])
      
      # Wait for Horde to heal
      Process.sleep(2000)
      
      # All sessions should be consistent after healing
      assert session_exists_on_node?(node_a, session_a)
      assert session_exists_on_node?(node_b, session_b)
      assert session_exists_on_node?(node_c, session_c)
      
      # Cross-node visibility restored
      assert session_exists_on_node?(node_a, session_b)
      assert session_exists_on_node?(node_b, session_a)
    end
  end
end
```

#### Step 4.3: Running Distributed Tests

**File:** `Makefile`

```makefile
# Start distributed test cluster
test-distributed:
	@echo "🚀 Starting 3-node test cluster..."
	MIX_ENV=test mix test --only distributed --trace

# Interactive cluster shell (for debugging)
cluster-shell:
	iex --sname debug@127.0.0.1 --cookie test_cookie -S mix

# Connect to running test node
cluster-connect:
	iex --sname client@127.0.0.1 --cookie test_cookie --remsh snakepit_test_a@127.0.0.1
```

**Usage:**

```bash
# Run distributed tests
make test-distributed

# Debug in interactive cluster
make cluster-shell

# In another terminal, connect to node A
make cluster-connect
```

---

### Phase 5: Observability for Distributed Systems (Week 3)

#### Step 5.1: Distributed Tracing

**File:** `lib/snakepit/telemetry.ex` (enhance existing)

```elixir
defmodule Snakepit.Telemetry do
  @moduledoc """
  Distributed telemetry with OpenTelemetry integration.
  """
  
  require OpenTelemetry.Tracer, as: Tracer
  
  def trace_distributed_execute(session_id, command, args, fun) do
    Tracer.with_span "snakepit.execute", %{
      "session.id" => session_id,
      "command" => command,
      "node.source" => node(),
      "node.target" => determine_target_node(session_id)
    } do
      result = fun.()
      
      # Add result attributes
      Tracer.set_attributes(%{
        "result.success" => match?({:ok, _}, result)
      })
      
      result
    end
  end
  
  defp determine_target_node(session_id) do
    # Reuse routing logic
    Snakepit.Pool.Distributed.determine_target_node(session_id)
  end
end
```

**Visualization:** Use Jaeger or Zipkin to see request flows across nodes.

#### Step 5.2: Cluster Health Dashboard

**File:** `lib/snakepit_web/live/cluster_live.ex` (Phoenix LiveView)

```elixir
defmodule SnakepitWeb.ClusterLive do
  use Phoenix.LiveView
  
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :update)
    end
    
    {:ok, assign(socket, nodes: [], sessions: [], workers: [])}
  end
  
  def handle_info(:update, socket) do
    nodes = [node() | Node.list()] |> Enum.map(&node_info/1)
    sessions = get_cluster_sessions()
    workers = get_cluster_workers()
    
    {:noreply, assign(socket, nodes: nodes, sessions: sessions, workers: workers)}
  end
  
  def render(assigns) do
    ~H"""
    <div class="cluster-dashboard">
      <h1>Snakepit Cluster Status</h1>
      
      <section class="nodes">
        <h2>Nodes (<%= length(@nodes) %>)</h2>
        <%= for node <- @nodes do %>
          <div class={"node node-#{node.status}"}>
            <h3><%= node.name %></h3>
            <p>Workers: <%= node.worker_count %></p>
            <p>Sessions: <%= node.session_count %></p>
            <p>CPU: <%= node.cpu_usage %>%</p>
            <p>Memory: <%= node.memory_mb %>MB</p>
          </div>
        <% end %>
      </section>
      
      <section class="sessions">
        <h2>Active Sessions (<%= length(@sessions) %>)</h2>
        <%= for session <- @sessions do %>
          <div class="session">
            <p><strong><%= session.id %></strong></p>
            <p>Node: <%= session.node %></p>
            <p>Age: <%= session.age_seconds %>s</p>
          </div>
        <% end %>
      </section>
    </div>
    """
  end
  
  defp node_info(node) do
    # RPC call to get node stats
    %{
      name: node,
      status: :healthy,
      worker_count: :rpc.call(node, Snakepit.Pool, :worker_count, []),
      session_count: :rpc.call(node, Snakepit.Bridge.SessionStore, :count, []),
      cpu_usage: :rpc.call(node, :cpu_sup, :avg1, []) / 256 * 100,
      memory_mb: :rpc.call(node, :erlang, :memory, [:total]) / 1_024 / 1_024
    }
  end
  
  defp get_cluster_sessions do
    # Aggregate sessions from all nodes
    [node() | Node.list()]
    |> Enum.flat_map(fn node ->
      :rpc.call(node, Snakepit.Bridge.SessionStore, :list_sessions, [])
      |> Enum.map(&%{id: &1, node: node, age_seconds: 0})
    end)
  end
  
  defp get_cluster_workers do
    # Similar aggregation for workers
    []
  end
end
```

---

## Part 4: Production Deployment Patterns

### Docker Compose (Local Multi-Node Dev)

**File:** `docker-compose.yml`

```yaml
version: '3.8'

services:
  snakepit-a:
    build: .
    hostname: snakepit-a
    environment:
      - NODE_NAME=snakepit@snakepit-a
      - COOKIE=secret_cookie
      - POOL_SIZE=50
      - HORDE_ENABLED=true
    ports:
      - "4000:4000"
    networks:
      - snakepit-cluster

  snakepit-b:
    build: .
    hostname: snakepit-b
    environment:
      - NODE_NAME=snakepit@snakepit-b
      - COOKIE=secret_cookie
      - POOL_SIZE=50
      - HORDE_ENABLED=true
    ports:
      - "4001:4000"
    networks:
      - snakepit-cluster

  snakepit-c:
    build: .
    hostname: snakepit-c
    environment:
      - NODE_NAME=snakepit@snakepit-c
      - COOKIE=secret_cookie
      - POOL_SIZE=50
      - HORDE_ENABLED=true
    ports:
      - "4002:4000"
    networks:
      - snakepit-cluster

networks:
  snakepit-cluster:
    driver: bridge
```

### Kubernetes Deployment

**File:** `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: snakepit
spec:
  serviceName: snakepit
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
        image: snakepit:latest
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          value: "snakepit@$(POD_IP)"
        - name: RELEASE_COOKIE
          valueFrom:
            secretKeyRef:
              name: snakepit-secret
              key: cookie
        - name: CLUSTER_STRATEGY
          value: "kubernetes"
        - name: KUBERNETES_SELECTOR
          value: "app=snakepit"
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        ports:
        - containerPort: 4000
          name: http
        - containerPort: 4369
          name: epmd
        - containerPort: 9000-9100
          name: dist
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 4000
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: snakepit
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

---

## Part 5: Performance Tuning for Distributed Mode

### Network Optimization

**File:** `config/runtime.exs`

```elixir
import Config

if config_env() == :prod do
  # Optimize Erlang distribution protocol
  config :kernel,
    inet_dist_listen_min: 9000,
    inet_dist_listen_max: 9100,
    inet_dist_use_interface: {0, 0, 0, 0}
  
  # Tune Horde for high throughput
  config :horde,
    delta_crdt_options: [
      sync_interval: 200,  # Sync every 200ms (default: 300ms)
      ship_interval: 100,  # Ship deltas every 100ms (default: 200ms)
      ship_debounce: 50    # Debounce ships by 50ms (default: 100ms)
    ]
end
```

### Monitoring Critical Metrics

```elixir
# Key metrics to track in distributed mode:

# 1. Inter-node latency
:telemetry.execute([:snakepit, :rpc, :latency], %{duration_ms: duration})

# 2. Session distribution skew
nodes_with_sessions = count_sessions_per_node()
skew = (max - min) / avg  # Should be < 0.3

# 3. Horde sync lag
:telemetry.execute([:horde, :sync, :lag], %{lag_ms: lag})

# 4. Network partition events
:telemetry.execute([:snakepit, :cluster, :partition], %{affected_nodes: nodes})
```

---

## Part 6: Common Pitfalls & Solutions

### Pitfall 1: Split-Brain During Network Partition

**Problem:** Two partitions both think they're authoritative for a session.

**Solution:** Use Horde's built-in conflict resolution (LWW - Last Write Wins) or implement manual quorum checks.

```elixir
# Ensure majority quorum for critical operations
def execute_with_quorum(command, args, opts) do
  nodes = [node() | Node.list()]
  
  if length(nodes) < 3 do
    {:error, :insufficient_nodes_for_quorum}
  else
    # Execute on majority of nodes
    results = Enum.map(nodes, fn node ->
      :rpc.call(node, Snakepit.Pool, :execute_local, [command, args, opts])
    end)
    
    successes = Enum.count(results, &match?({:ok, _}, &1))
    
    if successes > div(length(nodes), 2) do
      # Majority succeeded
      Enum.find(results, &match?({:ok, _}, &1))
    else
      {:error, :quorum_not_reached}
    end
  end
end
```

### Pitfall 2: Worker Affinity Broken After Node Restart

**Problem:** Session has affinity to Node A, but Node A restarts and loses all workers.

**Solution:** Store worker capabilities in Horde, re-route to healthy nodes.

```elixir
# Track worker capabilities in distributed registry
def register_worker_capabilities(worker_id) do
  Horde.Registry.register(
    WorkerCapabilities,
    worker_id,
    %{
      node: node(),
      adapter: :grpc_python,
      max_memory_mb: 2048,
      gpu_available: false
    }
  )
end

# Route to any compatible worker, not just original node
def find_compatible_worker(requirements) do
  WorkerCapabilities
  |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  |> Enum.find(fn {_worker_id, _pid, capabilities} ->
    meets_requirements?(capabilities, requirements)
  end)
end
```

### Pitfall 3: Python Process Orphans After Node Crash

**Problem:** Node crashes, Python processes keep running on that host.

**Solution:** Use systemd or supervisord **on the host level**, not in Snakepit. Configure to kill all child processes when Snakepit stops.

```systemd
# /etc/systemd/system/snakepit.service
[Unit]
Description=Snakepit Python Orchestrator
After=network.target

[Service]
Type=simple
User=snakepit
ExecStart=/usr/local/bin/snakepit start
KillMode=control-group  # ← Kills all child processes
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## Part 7: Migration Path for Existing Users

### Step 1: Single-Node → Multi-Node (Zero Downtime)

```elixir
# Week 1: Deploy with ETS adapter (no behavior change)
config :snakepit, session_adapter: Snakepit.SessionStore.ETS

# Week 2: Add 2nd node, still using ETS (nodes independent)
# Deploy Node B with same config

# Week 3: Switch to Horde adapter
config :snakepit, session_adapter: Snakepit.SessionStore.Horde

# Restart nodes one at a time (rolling restart)
# Horde will automatically form cluster
```

### Step 2: Data Migration (ETS/DETS → Horde)

```elixir
defmodule Snakepit.SessionStore.Migrator do
  @moduledoc """
  Migrates sessions from ETS/DETS to Horde during upgrade.
  """
  
  def migrate_to_horde do
    # 1. Read all sessions from DETS
    {:ok, dets_sessions} = Snakepit.SessionStore.ETS.export_all()
    
    # 2. Write to Horde
    Enum.each(dets_sessions, fn {session_id, session_data} ->
      Snakepit.SessionStore.Horde.create_session(session_id, metadata: session_data)
    end)
    
    # 3. Verify migration
    dets_count = length(dets_sessions)
    horde_count = length(Snakepit.SessionStore.Horde.list_sessions())
    
    if dets_count == horde_count do
      {:ok, "Migrated #{dets_count} sessions"}
    else
      {:error, "Migration incomplete: #{dets_count} → #{horde_count}"}
    end
  end
end
```

---

## Part 8: Benchmarking & Validation

### Performance Benchmarks

**File:** `bench/distributed_bench.exs`

```elixir
# Benchmark distributed vs single-node performance
Benchee.run(%{
  "single-node execute" => fn ->
    Snakepit.execute("ping", %{})
  end,
  
  "distributed execute (local)" => fn ->
    Snakepit.Pool.Distributed.execute("ping", %{}, session_id: "local_session")
  end,
  
  "distributed execute (remote)" => fn ->
    Snakepit.Pool.Distributed.execute("ping", %{}, session_id: "remote_session")
  end
}, time: 10, memory_time: 2)

# Expected results:
# single-node:    < 1ms latency
# distributed local:   1-2ms latency (routing overhead)
# distributed remote:  5-10ms latency (RPC + routing)
```

### Chaos Engineering Tests

**File:** `test/chaos/network_partition_test.exs`

```elixir
defmodule Snakepit.Chaos.NetworkPartitionTest do
  use Snakepit.ClusterCase
  
  @tag :chaos
  test "system recovers from temporary network partition", %{nodes: nodes} do
    [node_a, node_b, node_c] = nodes
    
    # 1. Create 100 sessions distributed across nodes
    sessions = for n <- 1..100 do
      create_session_on_node(Enum.random(nodes), "chaos_session_#{n}")
    end
    
    # 2. Partition node A from B and C
    :rpc.call(node_a, :erlang, :disconnect_node, [node_b])
    :rpc.call(node_a, :erlang, :disconnect_node, [node_c])
    
    # 3. Continue operations during partition
    Process.sleep(5000)
    
    # 4. Heal partition
    :rpc.call(node_a, :net_kernel, :connect_node, [node_b])
    :rpc.call(node_a, :net_kernel, :connect_node, [node_c])
    
    # 5. Wait for Horde to converge
    Process.sleep(5000)
    
    # 6. Verify all sessions still exist
    lost_sessions = Enum.filter(sessions, fn session_id ->
      not session_exists_on_any_node?(nodes, session_id)
    end)
    
    assert length(lost_sessions) == 0, "Lost #{length(lost_sessions)} sessions!"
  end
  
  defp session_exists_on_any_node?(nodes, session_id) do
    Enum.any?(nodes, &session_exists_on_node?(&1, session_id))
  end
end
```

---

## Summary: Your 3-Week Roadmap

### Week 1: Foundation
- [ ] **Day 1-2:** Implement `SessionStore.Adapter` behaviour
- [ ] **Day 3-4:** Refactor current code to use ETS adapter
- [ ] **Day 5:** Create example Horde adapter (reference implementation)

### Week 2: Distribution
- [ ] **Day 1-2:** Implement distributed routing (`Pool.Distributed`)
- [ ] **Day 3:** Add cluster formation (`Snakepit.Cluster` + libcluster)
- [ ] **Day 4-5:** Build multi-node test infrastructure

### Week 3: Production Readiness
- [ ] **Day 1-2:** Write distributed tests (split-brain, failover)
- [ ] **Day 3:** Add observability (telemetry, LiveView dashboard)
- [ ] **Day 4-5:** Write migration guide and benchmarks

---

## The One-Liner You Need to Remember

> **Workers are local, sessions are global, routing is smart.**

That's the entire distributed architecture. Everything else is implementation details.

---

**Ready to start?** I recommend beginning with Phase 1 (adapter behaviour) because it's **non-breaking** and sets you up for everything else. Want me to generate the actual code files for you to copy-paste?
