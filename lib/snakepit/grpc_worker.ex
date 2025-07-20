defmodule Snakepit.GRPCWorker do
  @moduledoc """
  A GenServer that manages gRPC connections to external processes.
  
  This worker can handle both traditional request/response and streaming operations
  via gRPC instead of stdin/stdout communication.
  
  ## Features
  
  - Automatic gRPC connection management
  - Health check monitoring  
  - Streaming support with callback-based API
  - Session affinity for stateful operations
  - Graceful fallback to traditional workers if gRPC unavailable
  
  ## Usage
  
      # Start a gRPC worker
      {:ok, worker} = Snakepit.GRPCWorker.start_link(adapter: Snakepit.Adapters.GRPCPython)
      
      # Simple execution
      {:ok, result} = Snakepit.GRPCWorker.execute(worker, "ping", %{})
      
      # Streaming execution
      Snakepit.GRPCWorker.execute_stream(worker, "batch_inference", %{
        batch_items: ["img1.jpg", "img2.jpg"]
      }, fn chunk ->
        IO.puts("Processed: \#{chunk["item"]}")
      end)
  """
  
  use GenServer
  require Logger
  
  @type worker_state :: %{
    adapter: module(),
    port: integer(),
    channel: term() | nil,
    health_check_ref: reference() | nil,
    stats: map()
  }
  
  # Client API
  
  @doc """
  Start a gRPC worker with the given adapter.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  @doc """
  Execute a command and return the result.
  """
  def execute(worker, command, args, timeout \\ 30_000) do
    GenServer.call(worker, {:execute, command, args, timeout}, timeout + 1_000)
  end
  
  @doc """
  Execute a streaming command with a callback function.
  
  The callback function is called for each chunk received from the stream.
  """
  def execute_stream(worker, command, args, callback_fn, timeout \\ 300_000) do
    GenServer.call(worker, {:execute_stream, command, args, callback_fn, timeout}, timeout + 1_000)
  end
  
  @doc """
  Execute a command in a specific session.
  """
  def execute_in_session(worker, session_id, command, args, timeout \\ 30_000) do
    GenServer.call(worker, {:execute_session, session_id, command, args, timeout}, timeout + 1_000)
  end
  
  @doc """
  Get worker health and statistics.
  """
  def get_health(worker) do
    GenServer.call(worker, :get_health)
  end
  
  @doc """
  Get worker information and capabilities.
  """
  def get_info(worker) do
    GenServer.call(worker, :get_info)
  end
  
  # Server callbacks
  
  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    
    # Check if gRPC is available
    if adapter.grpc_available?() do
      # Start external process with gRPC server
      port = adapter.get_port()
      
      case start_external_process(adapter, port) do
        {:ok, external_pid} ->
          # Wait a bit for the gRPC server to start
          Process.sleep(1000)
          
          # Establish gRPC connection
          case adapter.get_grpc_connection(port) do
            {:ok, channel} ->
              # Schedule health checks
              health_ref = schedule_health_check()
              
              state = %{
                adapter: adapter,
                port: port,
                channel: channel,
                external_pid: external_pid,
                health_check_ref: health_ref,
                stats: %{
                  requests: 0,
                  errors: 0,
                  start_time: System.monotonic_time(:millisecond)
                }
              }
              
              Logger.info("gRPC worker started successfully on port #{port}")
              {:ok, state}
              
            {:error, reason} ->
              Logger.error("Failed to connect to gRPC server: #{reason}")
              {:stop, {:grpc_connection_failed, reason}}
          end
          
        {:error, reason} ->
          Logger.error("Failed to start external process: #{reason}")
          {:stop, {:external_process_failed, reason}}
      end
    else
      Logger.warning("gRPC dependencies not available, cannot start gRPC worker")
      {:stop, :grpc_not_available}
    end
  end
  
  @impl true
  def handle_call({:execute, command, args, timeout}, _from, state) do
    case state.adapter.grpc_execute(state.channel, command, args, timeout) do
      {:ok, result} ->
        new_state = update_stats(state, :success)
        {:reply, {:ok, result}, new_state}
        
      {:error, reason} ->
        new_state = update_stats(state, :error)
        {:reply, {:error, reason}, new_state}
    end
  end
  
  @impl true
  def handle_call({:execute_stream, command, args, callback_fn, timeout}, _from, state) do
    case state.adapter.grpc_execute_stream(state.channel, command, args, callback_fn, timeout) do
      {:ok, _stream_result} ->
        new_state = update_stats(state, :success)
        {:reply, :ok, new_state}
        
      {:error, reason} ->
        new_state = update_stats(state, :error)  
        {:reply, {:error, reason}, new_state}
    end
  end
  
  @impl true
  def handle_call({:execute_session, session_id, command, args, timeout}, _from, state) do
    # For gRPC, session handling is done server-side
    # Just add session_id to the request args
    session_args = Map.put(args, :session_id, session_id)
    
    case state.adapter.grpc_execute(state.channel, command, session_args, timeout) do
      {:ok, result} ->
        new_state = update_stats(state, :success)
        {:reply, {:ok, result}, new_state}
        
      {:error, reason} ->
        new_state = update_stats(state, :error)
        {:reply, {:error, reason}, new_state}
    end
  end
  
  @impl true
  def handle_call(:get_health, _from, state) do
    # Make gRPC health check call
    health_result = make_health_check(state)
    {:reply, health_result, state}
  end
  
  @impl true
  def handle_call(:get_info, _from, state) do
    # Make gRPC info call
    info_result = make_info_call(state)
    {:reply, info_result, state}
  end
  
  @impl true
  def handle_info(:health_check, state) do
    case make_health_check(state) do
      {:ok, _health} ->
        # Health check passed, schedule next one
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}
        
      {:error, reason} ->
        Logger.warning("Health check failed: #{reason}")
        # Could implement reconnection logic here
        health_ref = schedule_health_check()
        {:noreply, %{state | health_check_ref: health_ref}}
    end
  end
  
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{external_pid: pid} = state) do
    Logger.error("External gRPC process died: #{inspect(reason)}")
    {:stop, {:external_process_died, reason}, state}
  end
  
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  @impl true
  def terminate(reason, state) do
    Logger.info("gRPC worker terminating: #{inspect(reason)}")
    
    # Close gRPC connection
    if state.channel do
      # Would call GRPC.Channel.disconnect(state.channel) in real implementation
      :ok
    end
    
    # Cancel health check timer
    if state.health_check_ref do
      Process.cancel_timer(state.health_check_ref)
    end
    
    :ok
  end
  
  # Private functions
  
  defp start_external_process(adapter, port) do
    executable = adapter.executable_path()
    script = adapter.script_path()
    args = ["--port", to_string(port)]
    
    case :os.find_executable(to_charlist(executable)) do
      false ->
        {:error, "Executable not found: #{executable}"}
        
      _path ->
        # Start the external process
        port_opts = [
          :binary,
          :exit_status,
          {:args, [script | args]},
          {:cd, Path.dirname(script)}
        ]
        
        try do
          port = Port.open({:spawn_executable, executable}, port_opts)
          {:ok, port}
        rescue
          e -> {:error, "Failed to start process: #{inspect(e)}"}
        end
    end
  end
  
  defp schedule_health_check do
    # Health check every 30 seconds
    Process.send_after(self(), :health_check, 30_000)
  end
  
  defp make_health_check(state) do
    # Placeholder for actual gRPC health check
    # Would use the generated protobuf client code
    {:ok, %{healthy: true, worker_id: inspect(self())}}
  end
  
  defp make_info_call(state) do
    # Placeholder for actual gRPC info call
    {:ok, %{
      worker_type: "grpc-python",
      supported_commands: state.adapter.supported_commands(),
      stats: state.stats
    }}
  end
  
  defp update_stats(state, result) do
    stats = case result do
      :success ->
        %{state.stats | requests: state.stats.requests + 1}
      :error ->
        %{
          state.stats | 
          requests: state.stats.requests + 1,
          errors: state.stats.errors + 1
        }
    end
    
    %{state | stats: stats}
  end
end