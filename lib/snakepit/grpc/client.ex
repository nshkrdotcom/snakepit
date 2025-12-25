defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client for the unified bridge protocol.
  Delegates to the real implementation when available.
  """

  require Logger
  alias Snakepit.GRPC.ClientImpl
  # Uncomment when logging is added to this module:
  # alias Snakepit.Logger, as: SLog

  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end

  def connect(address) when is_binary(address) do
    ClientImpl.connect(address)
  end

  def ping(channel, message, opts \\ []) do
    if mock_channel?(channel) do
      # Mock implementation
      {:ok, %{message: "Pong: #{message}", server_time: DateTime.utc_now()}}
    else
      ClientImpl.ping(channel, message, opts)
    end
  end

  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    if mock_channel?(channel) do
      # Mock implementation
      {:ok, %{success: true, available_tools: %{}}}
    else
      ClientImpl.initialize_session(channel, session_id, config, opts)
    end
  end

  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    if mock_channel?(channel) do
      # Mock implementation
      {:ok, %{success: true, resources_cleaned: 2}}
    else
      ClientImpl.cleanup_session(channel, session_id, force, opts)
    end
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if mock_channel?(channel) do
      if test_pid = Map.get(channel, :test_pid) do
        send(test_pid, {:grpc_client_execute_tool, session_id, tool_name, parameters, opts})
      end

      {:ok, %{success: true, result: %{}, error_message: ""}}
    else
      ClientImpl.execute_tool(channel, session_id, tool_name, parameters, opts)
    end
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if mock_channel?(channel) do
      if test_pid = Map.get(channel, :test_pid) do
        send(
          test_pid,
          {:grpc_client_execute_streaming_tool, session_id, tool_name, parameters, opts}
        )
      end

      # Mock implementation for testing - return a simple stream
      stream =
        Stream.iterate(1, &(&1 + 1))
        |> Stream.take(5)
        |> Stream.map(fn i ->
          {:ok,
           %{
             chunk_id: "mock-#{i}",
             data: Jason.encode!(%{"step" => i, "total" => 5}),
             is_final: i == 5
           }}
        end)

      {:ok, stream}
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
  def execute(channel, command, args, timeout \\ 30_000) do
    # Legacy support - redirect to execute_tool
    execute_tool(channel, "default_session", command, args, timeout: timeout)
  end

  def health(channel, client_id) do
    ping(channel, "health_check_#{client_id}")
  end

  def get_info(_channel) do
    # Return mock info for now
    {:ok,
     %{
       version: "1.0.0",
       capabilities: ["tools", "streaming"]
     }}
  end

  def get_session(channel, session_id, opts \\ []) do
    if mock_channel?(channel) do
      # Mock implementation
      {:ok, %{session: %{id: session_id, active: true}}}
    else
      ClientImpl.get_session(channel, session_id, opts)
    end
  end

  def heartbeat(channel, session_id, opts \\ []) do
    if mock_channel?(channel) do
      # Mock implementation
      {:ok, %{success: true}}
    else
      ClientImpl.heartbeat(channel, session_id, opts)
    end
  end

  defp mock_channel?(channel) when is_map(channel) do
    Map.get(channel, :mock, false)
  end

  defp mock_channel?(_channel), do: true
end
