defmodule Snakepit.GRPC.Client do
  @moduledoc """
  gRPC client for the unified bridge protocol.
  Delegates to the real implementation when available.
  """

  require Logger
  # Uncomment when logging is added to this module:
  # alias Snakepit.Logger, as: SLog

  def connect(port) when is_integer(port) do
    connect("localhost:#{port}")
  end

  def connect(address) when is_binary(address) do
    Snakepit.GRPC.ClientImpl.connect(address)
  end

  def ping(channel, message, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.ping(channel, message, opts)
    else
      # Mock implementation
      {:ok, %{message: "Pong: #{message}", server_time: DateTime.utc_now()}}
    end
  end

  def initialize_session(channel, session_id, config \\ %{}, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.initialize_session(channel, session_id, config, opts)
    else
      # Mock implementation
      {:ok, %{success: true, available_tools: %{}}}
    end
  end

  def cleanup_session(channel, session_id, force \\ false, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.cleanup_session(channel, session_id, force, opts)
    else
      # Mock implementation
      {:ok, %{success: true, resources_cleaned: 2}}
    end
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.execute_tool(channel, session_id, tool_name, parameters, opts)
    else
      if test_pid = Map.get(channel, :test_pid) do
        send(test_pid, {:grpc_client_execute_tool, session_id, tool_name, parameters, opts})
      end

      {:ok, %{success: true, result: %{}, error_message: ""}}
    end
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.execute_streaming_tool(
        channel,
        session_id,
        tool_name,
        parameters,
        opts
      )
    else
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
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.get_session(channel, session_id, opts)
    else
      # Mock implementation
      {:ok, %{session: %{id: session_id, active: true}}}
    end
  end

  def heartbeat(channel, session_id, opts \\ []) do
    if not mock_channel?(channel) do
      Snakepit.GRPC.ClientImpl.heartbeat(channel, session_id, opts)
    else
      # Mock implementation
      {:ok, %{success: true}}
    end
  end

  defp mock_channel?(channel) when is_map(channel) do
    Map.get(channel, :mock, false)
  end

  defp mock_channel?(_channel), do: true
end
