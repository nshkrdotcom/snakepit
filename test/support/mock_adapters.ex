defmodule Snakepit.TestAdapters.MockGRPCAdapter do
  @moduledoc """
  Mock gRPC adapter for testing without real Python processes.
  """

  @behaviour Snakepit.Adapter
  require Logger

  @impl true
  def executable_path do
    # Use a script that exits immediately with the expected output
    Path.join([__DIR__, "mock_grpc_server.sh"])
  end

  @impl true
  def script_path, do: ""

  @impl true
  def script_args, do: []

  @impl true
  def supported_commands do
    [
      "ping",
      "echo",
      "compute",
      "slow_operation",
      "initialize_session",
      "cleanup_session"
    ]
  end

  @impl true
  def validate_command(command, _args) do
    if command in supported_commands() do
      :ok
    else
      {:error, "Unsupported command: #{command}"}
    end
  end

  # Mock gRPC-specific functions
  def get_port, do: Snakepit.TestHelpers.allocate_test_port()

  def init_grpc_connection(port) do
    # Simulate successful connection
    {:ok, %{channel: make_ref(), port: port}}
  end

  def grpc_execute(_conn, _session_id, command, args, _timeout) do
    # Simulate command execution
    case command do
      "ping" ->
        {:ok, %{"status" => "pong", "worker_id" => "test_worker"}}

      "echo" ->
        {:ok, %{"echoed" => args}}

      "compute" ->
        {:ok, %{"result" => 42}}

      "slow_operation" ->
        delay = args["delay"] || 100

        receive do
        after
          delay -> :ok
        end

        {:ok, %{"status" => "completed"}}

      "initialize_session" ->
        {:ok, %{"session_id" => args["session_id"] || "test_session"}}

      "cleanup_session" ->
        {:ok, %{"status" => "cleaned"}}

      _ ->
        {:error, "Unknown command: #{command}"}
    end
  end

  def uses_grpc?, do: true
end

defmodule Snakepit.TestAdapters.FailingAdapter do
  @moduledoc """
  Adapter that fails in various ways for chaos testing.
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path, do: "false"

  @impl true
  def script_path, do: "/dev/null"

  @impl true
  def script_args, do: []

  @impl true
  def supported_commands, do: ["ping"]

  @impl true
  def validate_command(_command, _args), do: :ok

  def get_port, do: 60000

  def init_grpc_connection(_port) do
    {:error, :connection_refused}
  end

  def uses_grpc?, do: true
end

defmodule Snakepit.TestAdapters.EphemeralPortGRPCAdapter do
  @moduledoc false
  @behaviour Snakepit.Adapter

  @actual_port 61234

  def actual_port, do: @actual_port

  @impl true
  def executable_path do
    Path.join([__DIR__, "mock_grpc_server_ephemeral.sh"])
  end

  @impl true
  def script_path, do: ""

  @impl true
  def script_args, do: []

  @impl true
  def supported_commands, do: ["ping"]

  @impl true
  def validate_command(_command, _args), do: :ok

  def get_port, do: 0

  def init_grpc_connection(port) do
    {:ok,
     %{
       channel: %{
         mock: true,
         port: port,
         adapter: __MODULE__
       },
       port: port
     }}
  end

  def grpc_execute(_conn, _session_id, "ping", _args, _timeout) do
    {:ok, %{"status" => "pong"}}
  end

  def grpc_execute(_conn, _session_id, command, _args, _timeout) do
    {:error, {:unsupported_command, command}}
  end

  def uses_grpc?, do: true
end
