defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client for the unified bridge protocol.
  Delegates to the real implementation when available.
  """

  alias Snakepit.Defaults
  alias Snakepit.GRPC.ClientMock
  alias Snakepit.GRPC.ClientImpl

  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end

  def connect(address) when is_binary(address) do
    ClientImpl.connect(address)
  end

  def ping(channel, message, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.ping(channel, message, opts)
    else
      ClientImpl.ping(channel, message, opts)
    end
  end

  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.initialize_session(channel, session_id, config, opts)
    else
      ClientImpl.initialize_session(channel, session_id, config, opts)
    end
  end

  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.cleanup_session(channel, session_id, force, opts)
    else
      ClientImpl.cleanup_session(channel, session_id, force, opts)
    end
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.execute_tool(channel, session_id, tool_name, parameters, opts)
    else
      ClientImpl.execute_tool(channel, session_id, tool_name, parameters, opts)
    end
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.execute_streaming_tool(channel, session_id, tool_name, parameters, opts)
    else
      ClientImpl.execute_streaming_tool(
        channel,
        session_id,
        tool_name,
        parameters,
        opts
      )
    end
  end

  # Existing methods for backward compatibility
  def execute(channel, command, args, timeout \\ nil) do
    timeout = timeout || Defaults.grpc_command_timeout()
    # Legacy support - redirect to execute_tool
    execute_tool(channel, "default_session", command, args, timeout: timeout)
  end

  def health(channel, client_id, opts \\ []) do
    ping(channel, "health_check_#{client_id}", opts)
  end

  def get_info(channel) do
    if mock_channel?(channel) do
      ClientMock.get_info(channel)
    else
      ClientImpl.get_info(channel)
    end
  end

  def get_session(channel, session_id, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.get_session(channel, session_id, opts)
    else
      ClientImpl.get_session(channel, session_id, opts)
    end
  end

  def heartbeat(channel, session_id, opts \\ []) do
    if mock_channel?(channel) do
      ClientMock.heartbeat(channel, session_id, opts)
    else
      ClientImpl.heartbeat(channel, session_id, opts)
    end
  end

  defp mock_channel?(channel) when is_map(channel) do
    Map.get(channel, :mock, false)
  end

  defp mock_channel?(_channel), do: false
end
