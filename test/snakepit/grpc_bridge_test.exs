defmodule Snakepit.GRPCBridgeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  require Logger
  alias Snakepit.GRPCWorker, as: Worker
  alias Snakepit.GRPC.ClientImpl, as: Client

  # Start the gRPC server once for all tests
  setup_all do
    # Start the worker with the new gRPC bridge adapter
    {:ok, pid} =
      Worker.start_link(
        adapter: Snakepit.Adapters.GRPCBridge,
        id: :test_worker_grpc_bridge
      )

    # Get the channel
    {:ok, channel} = GenServer.call(pid, :get_channel)

    on_exit(fn ->
      # Properly terminate the worker
      if Process.alive?(pid) do
        GenServer.stop(pid, :shutdown, 5000)
      end
    end)

    {:ok, %{worker_pid: pid, channel: channel}}
  end

  setup %{channel: channel} do
    # Generate a unique session ID for each test
    session_id = "test_session_#{System.unique_integer([:positive])}"

    # Initialize session for this test
    {:ok, _} = Client.initialize_session(channel, session_id)

    # Clean up session after test
    on_exit(fn ->
      Client.cleanup_session(channel, session_id, true)
    end)

    {:ok, %{session_id: session_id}}
  end

  describe "gRPC bridge integration" do
    test "can start Python server and connect", %{channel: channel} do
      # Channel should be valid (already connected from setup_all)
      assert channel != nil
    end

    test "can ping the server", %{channel: channel} do
      # Test ping
      assert {:ok, response} = Client.ping(channel, "test message")
      assert response.message =~ "Pong"
    end

    test "can initialize a session", %{channel: channel, session_id: session_id} do
      # Session already initialized in setup, just verify it worked
      # We can try to register a variable as proof
      assert {:ok, _, _} =
               Client.register_variable(channel, session_id, "init_test", :string, "works")
    end

    test "can register and retrieve variables", %{channel: channel, session_id: session_id} do
      # Register a variable
      assert {:ok, var_id, variable} =
               Client.register_variable(
                 channel,
                 session_id,
                 "test_float",
                 :float,
                 3.14
               )

      assert var_id != nil
      assert variable[:name] == "test_float"
      assert variable[:type] == :float
      assert variable[:value] == 3.14

      # Get the variable
      assert {:ok, retrieved} = Client.get_variable(channel, session_id, "test_float")
      assert retrieved[:value] == 3.14
    end

    test "can update variables", %{channel: channel, session_id: session_id} do
      # Register a variable
      {:ok, _, _} =
        Client.register_variable(
          channel,
          session_id,
          "mutable",
          :integer,
          42
        )

      # Update it
      assert :ok = Client.set_variable(channel, session_id, "mutable", 100)

      # Verify update
      {:ok, updated} = Client.get_variable(channel, session_id, "mutable")
      assert updated[:value] == 100
    end

    test "enforces type constraints", %{channel: channel, session_id: session_id} do
      # Register with constraints
      assert {:ok, _, _} =
               Client.register_variable(
                 channel,
                 session_id,
                 "bounded",
                 :float,
                 0.5,
                 constraints: %{min: 0.0, max: 1.0}
               )

      # Valid update
      assert :ok = Client.set_variable(channel, session_id, "bounded", 0.7)

      # Invalid update
      assert {:error, _} = Client.set_variable(channel, session_id, "bounded", 1.5)
    end
  end
end
