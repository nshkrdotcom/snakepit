#!/usr/bin/env elixir

# Example 03: Session Affinity
# 
# This example demonstrates how Snakepit routes session-based requests
# to the same worker for stateful operations.

defmodule SessionAdapter do
  @moduledoc """
  An adapter that maintains per-worker state to demonstrate session affinity.
  
  This shows:
  - Session-based routing
  - Worker-local state
  - Session continuity
  """
  
  @behaviour Snakepit.Adapter
  require Logger
  use GenServer
  
  # Adapter Callbacks
  
  @impl Snakepit.Adapter
  def execute(command, args, opts) do
    worker_pid = Keyword.fetch!(opts, :worker_pid)
    GenServer.call(worker_pid, {:execute, command, args, opts})
  end
  
  @impl Snakepit.Adapter
  def start_worker(_adapter_state, worker_id) do
    # Start a GenServer for each worker to maintain state
    GenServer.start_link(__MODULE__, worker_id)
  end
  
  @impl Snakepit.Adapter
  def init(_config) do
    {:ok, %{started_at: DateTime.utc_now()}}
  end
  
  # GenServer Implementation (Worker Process)
  
  def init(worker_id) do
    Logger.info("Worker #{worker_id} starting")
    
    state = %{
      worker_id: worker_id,
      sessions: %{},  # Map of session_id -> session_state
      request_count: 0
    }
    
    {:ok, state}
  end
  
  def handle_call({:execute, command, args, opts}, _from, state) do
    session_id = Keyword.get(opts, :session_id, "no_session")
    state = update_in(state.request_count, &(&1 + 1))
    
    {result, new_state} = handle_command(command, args, session_id, state)
    
    {:reply, result, new_state}
  end
  
  # Command Handlers
  
  defp handle_command("start_session", args, session_id, state) do
    name = Map.get(args, "name", "Anonymous")
    
    session_state = %{
      name: name,
      started_at: DateTime.utc_now(),
      data: %{},
      operations: []
    }
    
    new_state = put_in(state.sessions[session_id], session_state)
    
    result = {:ok, %{
      session_id: session_id,
      worker_id: state.worker_id,
      message: "Session started for #{name}"
    }}
    
    {result, new_state}
  end
  
  defp handle_command("store", args, session_id, state) do
    key = Map.fetch!(args, "key")
    value = Map.fetch!(args, "value")
    
    case get_in(state.sessions, [session_id]) do
      nil ->
        {{:error, "Session not found: #{session_id}"}, state}
        
      session ->
        new_session = session
          |> update_in([:data], &Map.put(&1, key, value))
          |> update_in([:operations], &(["store:#{key}" | &1]))
        
        new_state = put_in(state.sessions[session_id], new_session)
        
        result = {:ok, %{
          stored: true,
          key: key,
          worker_id: state.worker_id,
          session_data_size: map_size(new_session.data)
        }}
        
        {result, new_state}
    end
  end
  
  defp handle_command("retrieve", args, session_id, state) do
    key = Map.fetch!(args, "key")
    
    case get_in(state.sessions, [session_id, :data, key]) do
      nil ->
        {{:error, "Key not found in session: #{key}"}, state}
        
      value ->
        new_state = update_in(state.sessions[session_id, :operations], 
          &(["retrieve:#{key}" | &1]))
        
        result = {:ok, %{
          key: key,
          value: value,
          worker_id: state.worker_id
        }}
        
        {result, new_state}
    end
  end
  
  defp handle_command("get_session_info", _args, session_id, state) do
    case get_in(state.sessions, [session_id]) do
      nil ->
        {{:error, "Session not found"}, state}
        
      session ->
        result = {:ok, %{
          session_id: session_id,
          worker_id: state.worker_id,
          name: session.name,
          started_at: session.started_at,
          data_keys: Map.keys(session.data),
          operation_count: length(session.operations),
          recent_operations: Enum.take(session.operations, 5)
        }}
        
        {result, state}
    end
  end
  
  defp handle_command("worker_info", _args, _session_id, state) do
    result = {:ok, %{
      worker_id: state.worker_id,
      request_count: state.request_count,
      active_sessions: map_size(state.sessions),
      session_ids: Map.keys(state.sessions)
    }}
    
    {result, state}
  end
  
  defp handle_command(cmd, _args, _session_id, state) do
    {{:error, "Unknown command: #{cmd}"}, state}
  end
end

# Configure Snakepit
Application.put_env(:snakepit, :adapter_module, SessionAdapter)
Application.put_env(:snakepit, :pooling_enabled, true)
Application.put_env(:snakepit, :pool_config, %{pool_size: 3})

# Run the example
Snakepit.run_as_script(fn ->
  IO.puts("\n=== Session Affinity Example ===\n")
  
  # Example 1: Create multiple sessions
  IO.puts("1. Creating three sessions on different workers:")
  
  sessions = for i <- 1..3 do
    session_id = "session_#{i}"
    {:ok, info} = Snakepit.execute_in_session(
      session_id, 
      "start_session", 
      %{"name" => "User #{i}"}
    )
    IO.puts("   Session #{i} started on worker: #{info.worker_id}")
    {session_id, info.worker_id}
  end
  
  # Example 2: Verify session affinity
  IO.puts("\n2. Verifying session affinity (multiple requests per session):")
  
  for {session_id, original_worker} <- sessions do
    # Make 3 requests in the same session
    workers = for j <- 1..3 do
      {:ok, result} = Snakepit.execute_in_session(
        session_id,
        "store",
        %{"key" => "key_#{j}", "value" => "value_#{j}"}
      )
      result.worker_id
    end
    
    unique_workers = Enum.uniq(workers)
    affinity_maintained = length(unique_workers) == 1 and hd(unique_workers) == original_worker
    
    IO.puts("   #{session_id}: Affinity maintained? #{affinity_maintained} (worker: #{original_worker})")
  end
  
  # Example 3: Store and retrieve data in sessions
  IO.puts("\n3. Storing and retrieving session data:")
  
  session_id = "data_session"
  
  # Start session
  Snakepit.execute_in_session(session_id, "start_session", %{"name" => "DataUser"})
  
  # Store multiple values
  for i <- 1..3 do
    {:ok, _} = Snakepit.execute_in_session(
      session_id,
      "store",
      %{"key" => "item_#{i}", "value" => "data_#{i}"}
    )
  end
  
  # Retrieve values
  for i <- 1..3 do
    {:ok, result} = Snakepit.execute_in_session(
      session_id,
      "retrieve",
      %{"key" => "item_#{i}"}
    )
    IO.puts("   Retrieved: #{result.key} = #{result.value} (from worker: #{result.worker_id})")
  end
  
  # Example 4: Get session information
  IO.puts("\n4. Session information:")
  {:ok, info} = Snakepit.execute_in_session(session_id, "get_session_info", %{})
  IO.inspect(info, label: "   Session details", pretty: true)
  
  # Example 5: Worker load distribution
  IO.puts("\n5. Worker load distribution:")
  
  # Create many sessions to see distribution
  test_sessions = for i <- 1..12 do
    session_id = "load_test_#{i}"
    {:ok, info} = Snakepit.execute_in_session(
      session_id,
      "start_session",
      %{"name" => "LoadTest#{i}"}
    )
    info.worker_id
  end
  
  # Count sessions per worker
  distribution = Enum.frequencies(test_sessions)
  IO.inspect(distribution, label: "   Sessions per worker")
  
  # Get worker info
  IO.puts("\n6. Worker information:")
  for worker_id <- Enum.uniq(test_sessions) |> Enum.take(3) do
    # Use a session known to be on this worker
    session_on_worker = Enum.find_value(Enum.with_index(test_sessions), fn {w_id, idx} ->
      if w_id == worker_id, do: "load_test_#{idx + 1}"
    end)
    
    {:ok, info} = Snakepit.execute_in_session(
      session_on_worker,
      "worker_info",
      %{}
    )
    IO.puts("   Worker #{worker_id}: #{info.request_count} requests, #{info.active_sessions} sessions")
  end
  
  IO.puts("\n=== Session affinity demonstrated! ===")
  IO.puts("\nKey insights:")
  IO.puts("- Sessions always route to the same worker")
  IO.puts("- Workers maintain independent state")
  IO.puts("- Load is distributed across workers")
  IO.puts("- Perfect for stateful operations\n")
end)

# Key Concepts Demonstrated:
#
# 1. SESSION ROUTING: execute_in_session/4 ensures same worker
# 2. WORKER STATE: Each worker maintains independent state
# 3. STATEFUL OPS: Store/retrieve operations work within sessions
# 4. LOAD BALANCING: New sessions distributed across workers
# 5. AFFINITY BENEFITS: Enables caching, transactions, etc.