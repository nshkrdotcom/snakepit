defmodule BridgeTestHelper do
  @moduledoc """
  Helper functions for bridge integration tests.
  """

  def start_bridge do
    # Ensure clean state
    cleanup_bridge()

    # Start the worker
    {:ok, _pid} = Snakepit.GRPC.Worker.start_link()

    # Wait for ready
    {:ok, channel} = Snakepit.GRPC.Worker.await_ready(30_000)

    channel
  end

  def cleanup_bridge do
    # Stop worker if running
    case Process.whereis(Snakepit.GRPC.Worker) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        Process.sleep(100)
    end
  end

  def create_test_session(channel) do
    session_id = "test_session_#{System.unique_integer([:positive])}"

    # Ensure session exists by making a call
    Snakepit.GRPC.Client.list_variables(channel, session_id)

    session_id
  end

  def with_timeout(timeout, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> flunk("Test timed out after #{timeout}ms")
    end
  end

  def wait_for_update(timeout \\ 5000) do
    receive do
      {:variable_update, update} -> update
    after
      timeout -> flunk("No update received within #{timeout}ms")
    end
  end
end
