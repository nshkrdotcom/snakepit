defmodule Snakepit.GRPC.BridgeServerTest do
  use Snakepit.TestCase, async: false

  alias GRPC.Status

  alias Google.Protobuf.{Any, Timestamp}

  alias Snakepit.Bridge.{
    ExecuteElixirToolRequest,
    ExecuteElixirToolResponse,
    ExecuteToolRequest,
    ExecuteToolResponse,
    InitializeSessionRequest,
    InitializeSessionResponse,
    PingRequest,
    PingResponse
  }

  alias Snakepit.Bridge.SessionStore
  alias Snakepit.Bridge.ToolRegistry
  alias Snakepit.GRPC.BridgeServer
  alias Snakepit.GRPCWorker

  setup do
    # Start SessionStore
    case SessionStore.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Create test session
    session_id = "test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Best effort cleanup - SessionStore may already be stopped
      try do
        SessionStore.delete_session(session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, session_id: session_id}
  end

  describe "ping/2" do
    test "responds with pong" do
      request = %PingRequest{message: "hello"}
      response = BridgeServer.ping(request, nil)

      assert %PingResponse{} = response
      assert response.message == "pong: hello"
      assert %Timestamp{} = response.server_time
    end
  end

  describe "initialize_session/2" do
    test "creates new session", %{session_id: session_id} do
      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{"source" => "test"}
      }

      response = BridgeServer.initialize_session(request, nil)

      assert %InitializeSessionResponse{} = response
      assert response.success == true
      assert response.error_message == nil
    end

    test "handles duplicate session gracefully", %{session_id: session_id} do
      # First create
      {:ok, _} = SessionStore.create_session(session_id)

      request = %InitializeSessionRequest{
        session_id: session_id,
        metadata: %{}
      }

      # Duplicate init should succeed (idempotent operation)
      response = BridgeServer.initialize_session(request, nil)
      assert response.success == true

      # Session should still exist and be usable
      assert {:ok, _session} = SessionStore.get_session(session_id)
    end
  end

  defmodule PoolStub do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:worker_ready, _worker_id}, _from, state) do
      {:reply, :ok, state}
    end
  end

  defmodule ChannelWorker do
    use GenServer

    def start_link({test_pid, worker_id}) do
      GenServer.start_link(__MODULE__, {test_pid, worker_id})
    end

    @impl true
    def init({test_pid, worker_id}) do
      Registry.register(Snakepit.Pool.Registry, worker_id, %{worker_module: Snakepit.GRPCWorker})
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call(:get_channel, _from, state) do
      {:reply, {:ok, %{mock: true, test_pid: state.test_pid}}, state}
    end

    def handle_call(:get_port, _from, state), do: {:reply, {:ok, 0}, state}
  end

  describe "execute_tool/2 with remote workers" do
    setup %{session_id: session_id} do
      ensure_tool_registry_started()
      ensure_started(Snakepit.Pool.Registry)
      ensure_started(Snakepit.Pool.ProcessRegistry)
      {:ok, pool_pid} = start_supervised(PoolStub)

      script_path =
        Path.join([__DIR__, "..", "..", "support", "mock_grpc_server_ephemeral.sh"])

      File.chmod!(script_path, 0o755)

      worker_id = "bridge_worker_#{System.unique_integer([:positive])}"

      {:ok, worker} =
        GRPCWorker.start_link(
          id: worker_id,
          adapter: Snakepit.TestAdapters.EphemeralPortGRPCAdapter,
          pool_name: pool_pid,
          worker_config: %{
            heartbeat: %{enabled: false}
          }
        )

      on_exit(fn ->
        if Process.alive?(worker) do
          try do
            GenServer.stop(worker)
          catch
            :exit, _ -> :ok
          end
        end

        ToolRegistry.cleanup_session(session_id)
      end)

      # Ensure session exists before tool registration
      {:ok, _session} = SessionStore.create_session(session_id)

      :ok =
        ToolRegistry.register_python_tool(
          session_id,
          "mock_tool",
          worker_id,
          %{}
        )

      assert_eventually(
        fn ->
          case GRPCWorker.get_channel(worker) do
            {:ok, _channel} -> true
            _ -> false
          end
        end,
        timeout: 5_000,
        interval: 25
      )

      {:ok,
       %{
         worker_id: worker_id,
         worker: worker,
         pool: pool_pid
       }}
    end

    test "returns success using the worker's established channel", %{
      session_id: session_id
    } do
      request = %ExecuteToolRequest{
        session_id: session_id,
        tool_name: "mock_tool",
        parameters: %{},
        metadata: %{}
      }

      response = BridgeServer.execute_tool(request, nil)

      assert %ExecuteToolResponse{success: true} = response
    end
  end

  describe "execute_elixir_tool/2" do
    test "returns error when parameters contain malformed JSON", %{session_id: session_id} do
      ensure_tool_registry_started()

      {:ok, _session} = SessionStore.create_session(session_id)

      :ok =
        ToolRegistry.register_elixir_tool(session_id, "echo", fn _params -> {:ok, :ok} end)

      request = %ExecuteElixirToolRequest{
        session_id: session_id,
        tool_name: "echo",
        parameters: %{
          "payload" => %Any{
            type_url: "type.googleapis.com/google.protobuf.StringValue",
            value: "not-json"
          }
        },
        metadata: %{}
      }

      response = BridgeServer.execute_elixir_tool(request, nil)

      assert %ExecuteElixirToolResponse{success: false, error_message: message} = response
      assert message =~ "Invalid parameter payload"
      assert response.result == nil
    end
  end

  describe "execute_streaming_tool/2" do
    test "raises UNIMPLEMENTED with remediation guidance", %{session_id: session_id} do
      request = %ExecuteToolRequest{
        session_id: session_id,
        tool_name: "unconfigured_stream_tool",
        parameters: %{},
        metadata: %{}
      }

      error =
        assert_raise GRPC.RPCError, fn ->
          BridgeServer.execute_streaming_tool(request, nil)
        end

      assert error.status == Status.unimplemented()
      assert String.contains?(error.message, "Enable streaming support")
      assert String.contains?(error.message, "execute_tool")
    end
  end

  defp ensure_tool_registry_started do
    case ToolRegistry.start_link() do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  describe "binary parameters" do
    test "local tools receive decoded binary payloads", %{session_id: session_id} do
      ensure_tool_registry_started()

      {:ok, _session} = SessionStore.create_session(session_id)

      parent = self()

      :ok =
        ToolRegistry.register_elixir_tool(session_id, "binary_tool", fn params ->
          send(parent, {:tool_params, params})
          {:ok, :ok}
        end)

      binary_payload = :erlang.term_to_binary(%{payload: "opaque"})

      request = %ExecuteToolRequest{
        session_id: session_id,
        tool_name: "binary_tool",
        parameters: %{
          "count" => %Any{
            type_url: "type.googleapis.com/google.protobuf.StringValue",
            value: Jason.encode!(1)
          }
        },
        binary_parameters: %{"blob" => binary_payload}
      }

      response = BridgeServer.execute_tool(request, nil)
      assert %ExecuteToolResponse{success: true} = response

      assert_receive {:tool_params, params}, 1_000
      assert params["count"] == 1
      assert params["blob"] == {:binary, binary_payload}

      ToolRegistry.cleanup_session(session_id)
    end

    test "remote execution forwards binary parameters to the worker", %{session_id: session_id} do
      ensure_tool_registry_started()
      ensure_started(Snakepit.Pool.Registry)

      {:ok, _session} = SessionStore.create_session(session_id)
      worker_id = "binary_remote_#{System.unique_integer([:positive])}"

      {:ok, worker_pid} = start_supervised({ChannelWorker, {self(), worker_id}})

      on_exit(fn ->
        ToolRegistry.cleanup_session(session_id)
        if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal)
      end)

      :ok =
        ToolRegistry.register_python_tool(
          session_id,
          "remote_binary_tool",
          worker_id,
          %{}
        )

      blob = <<0, 1, 2, 3>>

      request = %ExecuteToolRequest{
        session_id: session_id,
        tool_name: "remote_binary_tool",
        parameters: %{},
        metadata: %{"correlation_id" => "bridge-correlation-1"},
        binary_parameters: %{"blob" => blob}
      }

      response = BridgeServer.execute_tool(request, nil)
      assert %ExecuteToolResponse{success: true} = response

      assert_receive {:grpc_client_execute_tool, ^session_id, "remote_binary_tool", %{}, opts},
                     1_000

      assert opts[:binary_parameters] == %{"blob" => blob}
      assert opts[:correlation_id] == "bridge-correlation-1"
    end

    test "rejects binary parameters that are not binaries", %{session_id: session_id} do
      ensure_tool_registry_started()
      {:ok, _session} = SessionStore.create_session(session_id)

      parent = self()

      :ok =
        ToolRegistry.register_elixir_tool(session_id, "binary_tool", fn _params ->
          send(parent, :should_not_run)
          {:ok, :ok}
        end)

      request = %ExecuteToolRequest{
        session_id: session_id,
        tool_name: "binary_tool",
        parameters: %{},
        binary_parameters: %{"blob" => 123}
      }

      response = BridgeServer.execute_tool(request, nil)
      assert %ExecuteToolResponse{success: false, error_message: message} = response
      assert message =~ "Invalid parameter blob"
      assert message =~ "not_binary"

      refute_received :should_not_run

      ToolRegistry.cleanup_session(session_id)
      SessionStore.delete_session(session_id)
    end
  end

  defp ensure_started(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
