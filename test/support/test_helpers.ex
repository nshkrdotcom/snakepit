defmodule Snakepit.TestHelpers do
  @moduledoc """
  Snakepit-specific test helpers extending Supertester.
  """

  import ExUnit.Assertions

  alias Snakepit.Test.MockGRPCWorker

  @reserved_ports_table :snakepit_test_ports
  @max_port_attempts 50

  @doc """
  Allocate a unique port for gRPC testing.
  """
  def allocate_test_port do
    table = ensure_reserved_ports_table()
    reserve_available_port(@max_port_attempts, table)
  end

  @doc """
  Wait for gRPC server to be ready on given port.
  """
  def assert_grpc_server_ready(port, timeout \\ 5_000) do
    assert_receive {:grpc_ready, ^port}, timeout
  end

  @doc """
  Start a Python gRPC server for testing.
  """
  def with_python_server(port, fun) do
    # For now, use mock - real implementation would start Python process
    send(self(), {:grpc_ready, port})
    fun.()
  end

  @doc """
  Clean up all sessions after tests.
  """
  def cleanup_all_sessions do
    # SessionStore doesn't have list_all_sessions, so we can't clean up this way
    # In a real implementation, we might track sessions created during tests
    :ok
  end

  @doc """
  Create an isolated worker with unique naming.
  """
  def create_isolated_worker(test_name, opts \\ []) do
    worker_id = "test_worker_#{test_name}_#{System.unique_integer([:positive])}"
    port = Keyword.get(opts, :port, allocate_test_port())
    adapter = Keyword.get(opts, :adapter, Snakepit.TestAdapters.MockGRPCAdapter)

    worker_opts =
      [
        id: worker_id,
        adapter: adapter,
        port: port,
        test_pid: self()
      ] ++ opts

    # Use mock worker for tests
    {:ok, pid} = MockGRPCWorker.start_link(worker_opts)
    {pid, worker_id, port}
  end

  @doc """
  Assert that a streaming operation produces expected chunks.
  """
  def assert_streaming_response(stream_ref, expected_chunks) do
    Enum.each(expected_chunks, fn expected ->
      assert_receive {:stream_chunk, ^stream_ref, chunk}, 1_000
      assert chunk == expected
    end)

    assert_receive {:stream_end, ^stream_ref}, 1_000
  end

  # Note: Removed assert_process_restarted - was unused and had bugs
  # Use Supertester.OTPHelpers.wait_for_process_restart/3 instead

  @doc """
  Poll a condition until it's true or timeout occurs.

  Replacement for Process.sleep when waiting for eventual consistency.
  Uses receive timeouts instead of Process.sleep for deterministic synchronization.

  ## Parameters
  - `assertion_fn`: Function that returns true when condition is met
  - `opts`: Options
    - `:timeout` - Maximum time to wait in milliseconds (default: 5_000)
    - `:interval` - Polling interval in milliseconds (default: 10)

  ## Examples

      # Wait for session to be deleted
      assert_eventually(fn ->
        match?({:error, :not_found}, get_session(session_id))
      end)

      # Wait for process count to stabilize
      assert_eventually(fn ->
        count_processes(beam_run_id) == 0
      end, timeout: 10_000, interval: 100)
  """
  def assert_eventually(assertion_fn, opts \\ []) when is_function(assertion_fn, 0) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 10)

    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_true(assertion_fn, deadline, interval)
  end

  # Private helper for assert_eventually
  defp poll_until_true(assertion_fn, deadline, interval) do
    current_time = System.monotonic_time(:millisecond)

    if current_time >= deadline do
      # One final attempt, let it fail with proper assertion
      assert assertion_fn.(), "Condition did not become true within timeout"
    else
      if assertion_fn.() do
        :ok
      else
        # Wait using receive timeout (NOT Process.sleep)
        receive do
        after
          interval -> :ok
        end

        poll_until_true(assertion_fn, deadline, interval)
      end
    end
  end

  defp ensure_reserved_ports_table do
    case :ets.whereis(@reserved_ports_table) do
      :undefined ->
        try do
          :ets.new(@reserved_ports_table, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true}
          ])
        rescue
          ArgumentError -> :ets.whereis(@reserved_ports_table)
        end

      table ->
        table
    end
  end

  defp reserve_available_port(0, _table) do
    raise "Failed to allocate a unique test port after #{@max_port_attempts} attempts"
  end

  defp reserve_available_port(attempts, table) do
    case :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, {_addr, port}} = :inet.sockname(socket)
        :ok = :gen_tcp.close(socket)

        case reserve_port_in_table(table, port) do
          :ok ->
            port

          :retry ->
            reserve_available_port(attempts - 1, ensure_reserved_ports_table())
        end

      {:error, _reason} ->
        reserve_available_port(attempts - 1, table)
    end
  end

  defp reserve_port_in_table(table, port) do
    if :ets.insert_new(table, {port, true}) do
      :ok
    else
      :retry
    end
  rescue
    ArgumentError ->
      if :ets.insert_new(ensure_reserved_ports_table(), {port, true}) do
        :ok
      else
        :retry
      end
  end
end
