defmodule Snakepit.Adapters.GRPCBridge do
  @moduledoc """
  Adapter for the new unified gRPC bridge server.
  """

  @behaviour Snakepit.Adapter

  @impl true
  def executable_path, do: System.find_executable("python3") || "python3"

  @impl true
  def script_path, do: Path.join(:code.priv_dir(:snakepit), "python/grpc_server.py")

  @impl true
  def script_args do
    [
      # Dynamic port allocation
      "--port",
      "0",
      "--adapter",
      "snakepit_bridge.adapters.enhanced.EnhancedBridge"
    ]
  end

  @impl true
  def supported_commands do
    [
      # Variable operations
      "register_variable",
      "get_variable",
      "set_variable",
      "delete_variable",
      "list_variables",
      "watch_variable",
      # Tool operations (future)
      "register_tool",
      "execute_tool",
      "list_tools",
      # Session management
      "initialize_session",
      "cleanup_session",
      # Basic operations
      "ping"
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

  @impl true
  def prepare_args(_command, args), do: args

  @impl true
  def process_response(_command, response), do: {:ok, response}

  @impl true
  def command_timeout(_command, _args), do: 30_000

  # Additional adapter-specific functions
  def get_name, do: "GRPCBridge"

  # Let the server choose
  def get_port, do: 0

  def get_env, do: %{"PYTHONUNBUFFERED" => "1"}

  def supports_health?, do: true

  def grpc_enabled?, do: true

  def session_enabled?, do: true

  def validate_config(config) do
    {:ok, config}
  end

  def init_grpc_connection(port) do
    case Snakepit.GRPC.ClientImpl.connect(port) do
      {:ok, channel} ->
        {:ok, %{channel: channel, port: port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def uses_grpc?, do: true
end
