defmodule Snakepit.TestHelpers do
  @moduledoc """
  Snakepit-specific test helpers extending Supertester.
  """

  import ExUnit.Assertions

  @base_test_port 52000
  @port_range 1000

  @doc """
  Allocate a unique port for gRPC testing.
  """
  def allocate_test_port do
    # Use test PID to ensure unique ports
    test_id = :erlang.phash2(self())
    @base_test_port + rem(test_id, @port_range)
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
    {:ok, pid} = Snakepit.Test.MockGRPCWorker.start_link(worker_opts)
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

  @doc """
  Monitor a GenServer and assert it restarts within timeout.
  """
  def assert_process_restarted(monitor_ref, original_pid, timeout \\ 5_000) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^original_pid, _reason}, timeout
    # Give supervisor time to restart
    Process.sleep(100)
    # Process should be registered again
    assert Process.whereis(original_pid) != nil
  end
end
