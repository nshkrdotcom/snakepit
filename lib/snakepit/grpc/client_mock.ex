defmodule Snakepit.GRPC.ClientMock do
  @moduledoc false

  def ping(channel, message, opts \\ []) do
    cond do
      is_map(channel) and is_function(channel[:ping_fun], 2) ->
        channel[:ping_fun].(message, opts)

      is_map(channel) and is_function(channel[:ping_fun], 1) ->
        channel[:ping_fun].(message)

      true ->
        {:ok, %{message: "Pong: #{message}", server_time: DateTime.utc_now()}}
    end
  end

  def initialize_session(_channel, _session_id, _config \\ %{}, _opts \\ []) do
    {:ok, %{success: true, available_tools: %{}}}
  end

  def cleanup_session(_channel, _session_id, _force \\ false, _opts \\ []) do
    {:ok, %{success: true, resources_cleaned: 2}}
  end

  def execute_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if test_pid = mock_test_pid(channel) do
      send(test_pid, {:grpc_client_execute_tool, session_id, tool_name, parameters, opts})
    end

    {:ok, %{success: true, result: %{}, error_message: ""}}
  end

  def execute_streaming_tool(channel, session_id, tool_name, parameters, opts \\ []) do
    if test_pid = mock_test_pid(channel) do
      send(
        test_pid,
        {:grpc_client_execute_streaming_tool, session_id, tool_name, parameters, opts}
      )
    end

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

  def get_session(_channel, session_id, _opts \\ []) do
    {:ok, %{session: %{id: session_id, active: true}}}
  end

  def heartbeat(_channel, _session_id, _opts \\ []) do
    {:ok, %{success: true}}
  end

  def get_info(channel) do
    cond do
      is_map(channel) and is_function(channel[:get_info_fun], 0) ->
        channel[:get_info_fun].()

      is_map(channel) and Map.has_key?(channel, :get_info_result) ->
        channel[:get_info_result]

      true ->
        {:ok,
         %{
           version: "1.0.0",
           capabilities: ["tools", "streaming"]
         }}
    end
  end

  defp mock_test_pid(%{test_pid: test_pid}) when is_pid(test_pid), do: test_pid
  defp mock_test_pid(_), do: nil
end
