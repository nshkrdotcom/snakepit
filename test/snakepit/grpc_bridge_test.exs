defmodule Snakepit.GRPCBridgeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  require Logger
  alias Snakepit.GRPCWorker, as: Worker
  alias Snakepit.GRPC.ClientImpl, as: Client

  setup do
    # Clean up any existing worker
    case Process.whereis(Worker) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        Process.sleep(100)
    end

    on_exit(fn ->
      case Process.whereis(Worker) do
        nil ->
          :ok

        pid ->
          Process.exit(pid, :kill)
          Process.sleep(100)
      end
    end)
  end

  describe "gRPC bridge integration" do
    test "can start Python server and connect" do
      # Start the worker with the new gRPC bridge adapter
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      # Wait a bit for server to start
      Process.sleep(2000)

      # Get the channel directly from the worker pid
      assert {:ok, channel} = GenServer.call(pid, :get_channel)

      # Channel should be valid
      assert channel != nil
    end

    test "can ping the server" do
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      Process.sleep(2000)
      {:ok, channel} = GenServer.call(pid, :get_channel)

      # Test ping
      assert {:ok, response} = Client.ping(channel, "test message")
      assert response.message =~ "Pong"
    end

    test "can initialize a session" do
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      Process.sleep(2000)
      {:ok, channel} = GenServer.call(pid, :get_channel)

      session_id = "test_session_#{System.unique_integer([:positive])}"

      assert {:ok, response} = Client.initialize_session(channel, session_id)
      assert response.success == true
    end

    test "can register and retrieve variables" do
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      Process.sleep(2000)
      {:ok, channel} = GenServer.call(pid, :get_channel)

      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Initialize session
      {:ok, _} = Client.initialize_session(channel, session_id)

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

    test "can update variables" do
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      Process.sleep(2000)
      {:ok, channel} = GenServer.call(pid, :get_channel)

      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Initialize session
      {:ok, _} = Client.initialize_session(channel, session_id)

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

    test "enforces type constraints" do
      {:ok, pid} =
        Worker.start_link(
          adapter: Snakepit.Adapters.GRPCBridge,
          id: :test_worker
        )

      Process.sleep(2000)
      {:ok, channel} = GenServer.call(pid, :get_channel)

      session_id = "test_session_#{System.unique_integer([:positive])}"

      # Initialize session
      {:ok, _} = Client.initialize_session(channel, session_id)

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
