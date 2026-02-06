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
    # Simulate successful connection with explicit mock channel metadata.
    # This keeps behavior aligned with Snakepit.GRPC.Client's mock-channel contract.
    {:ok,
     %{
       channel: %{
         mock: true,
         adapter: __MODULE__,
         port: port
       },
       port: port
     }}
  end

  def grpc_execute(_conn, _session_id, command, args, _timeout, _opts \\ []) do
    # Simulate command execution
    execute_command(command, args)
  end

  def grpc_heartbeat(_connection, _session_id), do: {:ok, %{success: true}}
  def grpc_heartbeat(_connection, _session_id, _config), do: {:ok, %{success: true}}

  defp execute_command("ping", _args) do
    {:ok, %{"status" => "pong", "worker_id" => "test_worker"}}
  end

  defp execute_command("echo", args) do
    {:ok, %{"echoed" => args}}
  end

  defp execute_command("compute", _args) do
    {:ok, %{"result" => 42}}
  end

  defp execute_command("slow_operation", args) do
    delay = Map.get(args, "delay", Map.get(args, :delay, 100))

    receive do
    after
      delay -> :ok
    end

    {:ok, %{"status" => "completed"}}
  end

  defp execute_command("initialize_session", args) do
    {:ok, %{"session_id" => args["session_id"] || "test_session"}}
  end

  defp execute_command("cleanup_session", _args) do
    {:ok, %{"status" => "cleaned"}}
  end

  defp execute_command(command, _args) do
    {:error, "Unknown command: #{command}"}
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

  def supported_commands, do: ["ping"]

  def validate_command(_command, _args), do: :ok

  def get_port, do: 60_000

  def init_grpc_connection(_port) do
    {:error, :connection_refused}
  end

  def uses_grpc?, do: true
end

defmodule Snakepit.TestAdapters.EphemeralPortGRPCAdapter do
  @moduledoc false
  @behaviour Snakepit.Adapter

  @actual_port 61_234

  def actual_port, do: @actual_port

  @impl true
  def executable_path do
    Path.join([__DIR__, "mock_grpc_server_ephemeral.sh"])
  end

  @impl true
  def script_path, do: ""

  @impl true
  def script_args, do: []

  def supported_commands, do: ["ping"]

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

  def grpc_execute(_conn, _session_id, command, _args, _timeout, _opts \\ [])

  def grpc_execute(_conn, _session_id, "ping", _args, _timeout, _opts) do
    {:ok, %{"status" => "pong"}}
  end

  def grpc_execute(_conn, _session_id, command, _args, _timeout, _opts) do
    {:error, {:unsupported_command, command}}
  end

  def uses_grpc?, do: true
end

defmodule Snakepit.TestAdapters.ProcessGroupGRPCAdapter do
  @moduledoc false

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path do
    System.find_executable("python3") ||
      System.find_executable("python") ||
      raise "python executable not found (required for process group tests)"
  end

  @impl true
  def script_path do
    Path.join([__DIR__, "mock_grpc_server_process_group.py"])
  end

  @impl true
  def script_args, do: []

  # gRPC adapter functions used by GRPCWorker during startup
  def get_port, do: Snakepit.TestHelpers.allocate_test_port()

  def init_grpc_connection(_port) do
    # No real gRPC server is running in this test adapter.
    {:ok, %{channel: nil}}
  end

  def uses_grpc?, do: true
end
