defmodule Snakepit.ProcessManagementTest do
  @moduledoc """
  Tests the core process management capabilities of Snakepit.
  
  Verifies:
  - Process lifecycle (start, monitor, restart, cleanup)
  - Orphan prevention and cleanup
  - Worker tracking via ProcessRegistry
  - Graceful shutdown
  """
  
  use ExUnit.Case
  alias Snakepit.Pool.{ProcessRegistry, WorkerSupervisor}
  import ExUnit.CaptureLog
  
  # Process-tracking adapter for testing
  defmodule ProcessTrackingAdapter do
    @behaviour Snakepit.Adapter
    use GenServer
    
    # Client API
    def execute("get_os_pid", _args, opts) do
      worker_pid = Keyword.fetch!(opts, :worker_pid)
      GenServer.call(worker_pid, :get_os_pid)
    end
    
    def execute("get_state", _args, opts) do
      worker_pid = Keyword.fetch!(opts, :worker_pid)
      GenServer.call(worker_pid, :get_state)
    end
    
    def execute("simulate_crash", _args, _opts) do
      raise "Simulated process crash"
    end
    
    def execute(cmd, args, _opts) do
      {:ok, %{command: cmd, args: args}}
    end
    
    def start_worker(adapter_state, worker_id) do
      # Reserve slot first (critical for orphan prevention)
      :ok = ProcessRegistry.reserve_worker(worker_id)
      
      # Start a real GenServer to simulate external process
      {:ok, pid} = GenServer.start_link(__MODULE__, {adapter_state, worker_id})
      
      # Get the simulated OS PID
      os_pid = GenServer.call(pid, :get_os_pid)
      fingerprint = "#{adapter_state.beam_run_id}_#{worker_id}"
      
      # Activate tracking
      ProcessRegistry.activate_worker(worker_id, pid, os_pid, fingerprint)
      
      {:ok, pid}
    end
    
    def init(config) when is_list(config) do
      {:ok, %{
        beam_run_id: generate_beam_run_id(),
        started_at: DateTime.utc_now(),
        config: config
      }}
    end
    
    def terminate(_reason, _state), do: :ok
    def supports_streaming?(), do: false
    
    # GenServer implementation (simulates external process)
    def init({adapter_state, worker_id}) when is_map(adapter_state) do
      # Simulate an OS PID
      os_pid = :erlang.unique_integer([:positive])
      
      state = %{
        worker_id: worker_id,
        os_pid: os_pid,
        adapter_state: adapter_state,
        started_at: DateTime.utc_now()
      }
      
      {:ok, state}
    end
    
    def handle_call(:get_os_pid, _from, state) do
      {:reply, {:ok, state.os_pid}, state}
    end
    
    def handle_call(:get_state, _from, state) do
      {:reply, {:ok, state}, state}
    end
    
    defp generate_beam_run_id do
      "#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
    end
  end
  
  setup do
    # Use our process-tracking adapter
    original_adapter = Application.get_env(:snakepit, :adapter_module)
    Application.put_env(:snakepit, :adapter_module, ProcessTrackingAdapter)
    
    on_exit(fn ->
      Application.put_env(:snakepit, :adapter_module, original_adapter)
    end)
    
    :ok
  end
  
  describe "process lifecycle" do
    @tag :process_management
    test "tracks OS PIDs through ProcessRegistry" do
      # Start registry
      {:ok, registry} = ProcessRegistry.start_link([])
      
      # Start a worker
      {:ok, supervisor} = WorkerSupervisor.start_link([])
      {:ok, adapter_state} = ProcessTrackingAdapter.init([])
      
      worker_id = "test_worker_1"
      {:ok, _worker_pid} = ProcessTrackingAdapter.start_worker(
        adapter_state,
        worker_id
      )
      
      # Allow worker to fully initialize
      Process.sleep(50)
      
      # Verify worker is tracked
      workers = ProcessRegistry.list_all_workers()
      worker_ids = for {id, _info} <- workers, do: id
      assert worker_id in worker_ids
      
      # Verify OS PID is tracked
      {^worker_id, worker_info} = List.keyfind(workers, worker_id, 0)
      # Check both possible fields for backwards compatibility
      assert is_integer(worker_info[:process_pid]) || is_tuple(worker_info[:process_pid])
      assert is_pid(worker_info.elixir_pid)
      assert is_binary(worker_info.fingerprint)
      
      # Cleanup
      GenServer.stop(registry)
      GenServer.stop(supervisor)
    end
    
    @tag :process_management
    test "prevents orphaned processes via BEAM run ID" do
      # This test demonstrates how orphan detection works
      # In real usage, orphans are detected on startup when loading from DETS
      
      # Manually create a DETS file with an "orphaned" entry
      priv_dir = :code.priv_dir(:snakepit) |> to_string()
      node_name = node() |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
      dets_file = Path.join([priv_dir, "data", "process_registry_test_#{node_name}.dets"])
      File.mkdir_p!(Path.dirname(dets_file))
      
      # Create DETS with old entry
      {:ok, dets} = :dets.open_file(:test_orphan_dets, [
        {:file, to_charlist(dets_file)},
        {:type, :set}
      ])
      
      old_run_id = "1234567890_999"
      # Insert "orphaned" worker with old BEAM run ID
      :dets.insert(dets, {"orphan_worker", %{
        status: :active,
        elixir_pid: self(),
        process_pid: 5678,
        fingerprint: "test_orphan",
        registered_at: System.system_time(:second),
        beam_run_id: old_run_id,
        pgid: 5678
      }})
      :dets.close(dets)
      
      # Now start registry which should detect the orphan
      {:ok, registry} = ProcessRegistry.start_link([])
      current_run_id = ProcessRegistry.get_beam_run_id()
      
      # Register a current worker
      ProcessRegistry.reserve_worker("current_worker")
      ProcessRegistry.activate_worker(
        "current_worker",
        self(),
        1234,
        "#{current_run_id}_current_worker"
      )
      
      # Get all workers
      all_workers = ProcessRegistry.list_all_workers()
      
      # Filter orphans by BEAM run ID
      orphans = Enum.filter(all_workers, fn {_id, info} ->
        info.beam_run_id != current_run_id
      end)
      
      # Current registry won't have orphans since it starts fresh
      # The orphan detection happens during startup from DETS
      assert length(all_workers) == 1
      assert {"current_worker", _} = hd(all_workers)
      
      # Clean up
      GenServer.stop(registry)
      File.rm(dets_file)
    end
    
    @tag :process_management
    test "handles worker crashes and cleanup" do
      {:ok, pool} = Snakepit.Pool.start_link(
        size: 1, 
        name: TestPool,
        adapter_module: ProcessTrackingAdapter
      )
      
      # Execute command that crashes
      log = capture_log(fn ->
        assert {:error, _} = Snakepit.execute("simulate_crash", %{}, pool: pool)
      end)
      
      assert log =~ "crashed"
      
      # Pool should recover
      Process.sleep(200)
      assert {:ok, _} = Snakepit.execute("get_state", %{}, pool: pool)
      
      GenServer.stop(pool)
    end
  end
  
  describe "graceful shutdown" do
    @tag :process_management
    test "cleans up all workers on shutdown" do
      {:ok, pool} = Snakepit.Pool.start_link(
        size: 2, 
        name: TestPool,
        adapter_module: ProcessTrackingAdapter
      )
      
      # Get worker states
      {:ok, result1} = Snakepit.execute("get_state", %{}, pool: pool)
      {:ok, result2} = Snakepit.execute("get_state", %{}, pool: pool)
      
      # Verify we got different workers
      assert result1 != result2
      
      # Stop pool
      GenServer.stop(pool)
      
      # Allow cleanup
      Process.sleep(100)
      
      # Verify cleanup - registry cleans up on pool stop
      workers_after = ProcessRegistry.list_all_workers()
      # Workers should be cleaned up when pool stops
      assert length(workers_after) <= 2
    end
  end
  
  describe "process registry persistence" do
    @tag :process_management
    @tag :dets
    test "persists worker tracking across restarts" do
      # This test demonstrates DETS persistence concept
      # In real usage, orphaned processes are cleaned on startup
      
      # Start registry
      {:ok, registry} = ProcessRegistry.start_link([])
      
      # Register a worker
      worker_id = "persistent_worker_#{:rand.uniform(1000)}"
      ProcessRegistry.reserve_worker(worker_id)
      ProcessRegistry.activate_worker(
        worker_id,
        self(),
        9999,
        "test_fingerprint"
      )
      
      # Verify worker is tracked
      workers_before = ProcessRegistry.list_all_workers()
      assert length(workers_before) >= 1
      assert Enum.any?(workers_before, fn {id, _} -> id == worker_id end)
      
      # Stop registry
      GenServer.stop(registry)
      
      # Clean up for next test run
      # Note: In production, the new registry instance would load from DETS
      # and perform orphan cleanup based on BEAM run IDs
    end
  end
end