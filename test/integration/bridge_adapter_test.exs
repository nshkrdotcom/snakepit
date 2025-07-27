defmodule Snakepit.Integration.BridgeAdapterTest do
  @moduledoc """
  Integration tests for Snakepit with bridge adapters.
  
  These tests verify the contract between Snakepit infrastructure
  and bridge implementations without requiring actual Python/gRPC.
  """
  
  use ExUnit.Case
  require Logger
  import ExUnit.CaptureLog
  
  # Mock bridge adapter that simulates the real SnakepitGRPCBridge.Adapter
  defmodule MockBridgeAdapter do
    @behaviour Snakepit.Adapter
    use GenServer
    
    @impl Snakepit.Adapter
    def init(config) do
      # Simulate bridge initialization
      state = %{
        config: config,
        beam_run_id: generate_beam_run_id(),
        workers: %{},
        port_allocator: {50000, 50100, 50000}  # {min, max, next}
      }
      {:ok, state}
    end
    
    @impl Snakepit.Adapter
    def terminate(reason, state) do
      Logger.info("MockBridge terminating: #{inspect(reason)}")
      # Simulate cleanup of Python processes
      for {_id, worker} <- state.workers do
        if Process.alive?(worker.pid), do: GenServer.stop(worker.pid)
      end
      :ok
    end
    
    @impl Snakepit.Adapter
    def start_worker(adapter_state, worker_id) do
      # Simulate the bridge's worker startup sequence
      
      # 1. Reserve tracking slot (critical for orphan prevention)
      :ok = Snakepit.Pool.ProcessRegistry.reserve_worker(worker_id)
      
      # 2. Allocate resources (port for gRPC)
      {port, new_allocator} = allocate_port(adapter_state.port_allocator)
      
      # 3. Start worker process (simulates Python process)
      {:ok, pid} = GenServer.start_link(__MODULE__, {adapter_state, worker_id, port})
      
      # 4. Get process info for tracking
      os_pid = :erlang.unique_integer([:positive])  # Simulate OS PID
      fingerprint = "#{adapter_state.beam_run_id}_#{worker_id}"
      
      # 5. Activate tracking with ProcessRegistry
      Snakepit.Pool.ProcessRegistry.activate_worker(
        worker_id,
        pid,
        os_pid,
        fingerprint
      )
      
      # Update adapter state
      worker_info = %{pid: pid, port: port, os_pid: os_pid}
      new_state = %{adapter_state | 
        workers: Map.put(adapter_state.workers, worker_id, worker_info),
        port_allocator: new_allocator
      }
      
      # Return just the PID (adapter state updates handled elsewhere)
      {:ok, pid}
    end
    
    @impl Snakepit.Adapter
    def execute(command, args, opts) do
      worker_pid = Keyword.fetch!(opts, :worker_pid)
      timeout = Keyword.get(opts, :timeout, 30_000)
      
      try do
        GenServer.call(worker_pid, {:execute, command, args, opts}, timeout)
      catch
        :exit, {:noproc, _} ->
          {:error, :worker_died}
        :exit, {:timeout, _} ->
          {:error, :timeout}
      end
    end
    
    @impl Snakepit.Adapter
    def supports_streaming?(), do: true
    
    @impl Snakepit.Adapter
    def execute_stream(command, args, callback, opts) do
      worker_pid = Keyword.fetch!(opts, :worker_pid)
      GenServer.cast(worker_pid, {:stream, command, args, callback})
      :ok
    end
    
    # GenServer implementation for mock workers
    
    def init({adapter_state, worker_id, port}) do
      Logger.debug("MockBridge worker #{worker_id} starting on port #{port}")
      
      state = %{
        worker_id: worker_id,
        port: port,
        adapter_state: adapter_state,
        sessions: %{},
        request_count: 0
      }
      
      {:ok, state}
    end
    
    def handle_call({:execute, command, args, opts}, _from, state) do
      state = update_in(state.request_count, &(&1 + 1))
      session_id = Keyword.get(opts, :session_id)
      
      result = case command do
        "ping" -> 
          {:ok, %{response: "pong", worker_id: state.worker_id}}
          
        "get_info" ->
          {:ok, %{
            worker_id: state.worker_id,
            port: state.port,
            request_count: state.request_count,
            session_id: session_id
          }}
          
        "simulate_crash" ->
          raise "Simulated worker crash"
          
        "simulate_error" ->
          {:error, %{code: 500, message: "Simulated error"}}
          
        _ ->
          {:ok, %{command: command, args: args, worker_id: state.worker_id}}
      end
      
      {:reply, result, state}
    end
    
    def handle_cast({:stream, _command, _args, callback}, state) do
      # Simulate streaming
      Task.start(fn ->
        for i <- 1..3 do
          callback.(%{chunk: i, data: "chunk_#{i}"})
          Process.sleep(50)
        end
      end)
      
      {:noreply, state}
    end
    
    # Helper functions
    
    defp generate_beam_run_id do
      "#{:erlang.system_time(:millisecond)}_#{:rand.uniform(9999)}"
    end
    
    defp allocate_port({min, max, next}) when next <= max do
      {next, {min, max, next + 1}}
    end
    defp allocate_port({min, max, _next}) do
      {min, {min, max, min + 1}}
    end
  end
  
  setup do
    # Save original configuration
    original_adapter = Application.get_env(:snakepit, :adapter_module)
    original_pooling = Application.get_env(:snakepit, :pooling_enabled)
    
    # Configure for testing
    Application.put_env(:snakepit, :adapter_module, MockBridgeAdapter)
    Application.put_env(:snakepit, :pooling_enabled, true)
    Application.put_env(:snakepit, :pool_config, %{pool_size: 2})
    
    on_exit(fn ->
      Application.put_env(:snakepit, :adapter_module, original_adapter)
      Application.put_env(:snakepit, :pooling_enabled, original_pooling)
    end)
    
    :ok
  end
  
  describe "bridge adapter integration" do
    @tag :integration
    test "adapter lifecycle hooks are called correctly" do
      log = capture_log(fn ->
        {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
        Process.sleep(100)  # Allow workers to start
        GenServer.stop(pool)
      end)
      
      # Verify initialization
      assert log =~ "MockBridge worker"
      assert log =~ "starting on port"
      
      # Verify termination
      assert log =~ "MockBridge terminating"
    end
    
    @tag :integration
    test "bridge adapter handles basic commands" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      
      # Test basic execution
      assert {:ok, %{response: "pong"}} = Snakepit.execute("ping", %{}, pool: pool)
      
      # Test with args
      {:ok, info} = Snakepit.execute("get_info", %{}, pool: pool)
      assert is_binary(info.worker_id)
      assert is_integer(info.port)
      assert info.port >= 50000 and info.port < 50100
      
      GenServer.stop(pool)
    end
    
    @tag :integration
    test "bridge adapter maintains session affinity" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      session_id = "test_session_#{:rand.uniform(1000)}"
      
      # Make multiple requests with same session
      results = for _ <- 1..5 do
        {:ok, info} = Snakepit.execute("get_info", %{}, 
          pool: pool, 
          session_id: session_id
        )
        info
      end
      
      # All should have same worker_id
      worker_ids = Enum.map(results, & &1.worker_id)
      assert length(Enum.uniq(worker_ids)) == 1
      
      # Session ID should be preserved
      assert Enum.all?(results, & &1.session_id == session_id)
      
      GenServer.stop(pool)
    end
    
    @tag :integration
    test "bridge adapter handles streaming" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      
      chunks = []
      Snakepit.execute_stream("test_stream", %{}, fn chunk ->
        send(self(), {:chunk, chunk})
      end, pool: pool)
      
      # Collect chunks
      for _ <- 1..3 do
        assert_receive {:chunk, chunk}, 1000
        assert is_map(chunk)
        assert is_integer(chunk.chunk)
      end
      
      GenServer.stop(pool)
    end
    
    @tag :integration
    test "bridge adapter handles worker crashes gracefully" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      
      # Cause a crash
      log = capture_log(fn ->
        assert {:error, _} = Snakepit.execute("simulate_crash", %{}, pool: pool)
      end)
      
      assert log =~ "Worker crashed"
      
      # Pool should recover and work normally
      Process.sleep(100)
      assert {:ok, %{response: "pong"}} = Snakepit.execute("ping", %{}, pool: pool)
      
      GenServer.stop(pool)
    end
    
    @tag :integration
    test "bridge adapter properly integrates with ProcessRegistry" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      
      # Allow workers to start
      Process.sleep(100)
      
      # Check that workers are registered
      {:ok, workers} = Snakepit.Pool.ProcessRegistry.get_all_workers()
      assert map_size(workers) > 0
      
      # Verify worker info structure
      for {_worker_id, info} <- workers do
        assert is_pid(info.elixir_pid)
        assert is_integer(info.os_pid)
        assert is_binary(info.fingerprint)
        assert String.contains?(info.fingerprint, "_")
      end
      
      GenServer.stop(pool)
    end
    
    @tag :integration
    test "bridge adapter errors are properly propagated" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool)
      
      # Test error propagation
      assert {:error, %{code: 500, message: "Simulated error"}} = 
        Snakepit.execute("simulate_error", %{}, pool: pool)
      
      GenServer.stop(pool)
    end
  end
  
  describe "concurrent operations" do
    @tag :integration
    test "bridge adapter handles concurrent requests across workers" do
      {:ok, pool} = Snakepit.Pool.start_link(name: TestPool, size: 2)
      
      # Launch concurrent requests
      tasks = for i <- 1..10 do
        Task.async(fn ->
          {:ok, info} = Snakepit.execute("get_info", %{"request" => i}, pool: pool)
          info
        end)
      end
      
      results = Task.await_many(tasks)
      
      # Should have used both workers
      worker_ids = results |> Enum.map(& &1.worker_id) |> Enum.uniq()
      assert length(worker_ids) == 2
      
      # All requests should complete
      assert length(results) == 10
      
      GenServer.stop(pool)
    end
  end
end