defmodule SnakepitShowcase.Demo.ResourceTracker do
  @moduledoc """
  Tracks resources created during demo execution for cleanup.
  """
  
  use GenServer
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end
  
  def stop(tracker) do
    GenServer.stop(tracker)
  end
  
  def track_session(tracker, session_id) do
    GenServer.cast(tracker, {:track_session, session_id})
  end
  
  def track_resource(tracker, type, id) do
    GenServer.cast(tracker, {:track_resource, type, id})
  end
  
  def get_all(tracker) do
    GenServer.call(tracker, :get_all)
  end
  
  @impl true
  def init(:ok) do
    {:ok, %{sessions: [], resources: []}}
  end
  
  @impl true
  def handle_cast({:track_session, session_id}, state) do
    {:noreply, %{state | sessions: [session_id | state.sessions]}}
  end
  
  @impl true
  def handle_cast({:track_resource, type, id}, state) do
    {:noreply, %{state | resources: [{type, id} | state.resources]}}
  end
  
  @impl true
  def handle_call(:get_all, _from, state) do
    {:reply, state, state}
  end
end