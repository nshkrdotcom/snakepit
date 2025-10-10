defmodule Snakepit.GRPC.StreamHandler do
  @moduledoc """
  Handles gRPC streaming responses for variable watching.
  """

  require Logger

  @doc """
  Consume a gRPC stream and call the handler function for each update.

  The handler function receives: (name, old_value, new_value, metadata)
  """
  def consume_stream(stream, handler_fn) when is_function(handler_fn, 4) do
    Task.async(fn ->
      stream
      |> Stream.each(fn
        {:ok, update} ->
          try do
            handle_update(update, handler_fn)
          catch
            error, reason ->
              Logger.error("Error in stream handler: #{inspect({error, reason})}")
          end

        {:error, error} ->
          Logger.error("Stream error: #{inspect(error)}")
      end)
      |> Stream.run()
    end)
  end

  defp handle_update(update, handler_fn) do
    case update.update_type do
      "value_changed" ->
        # Decode old and new values
        old_value = decode_any_value(update.old_value)
        new_value = decode_any_value(update.new_value)
        metadata = Map.new(update.metadata)

        # Call handler
        handler_fn.(update.variable.name, old_value, new_value, metadata)

      "initial" ->
        # Initial value update
        value = decode_any_value(update.variable.value)
        handler_fn.(update.variable.name, nil, value, %{initial: true})

      "heartbeat" ->
        # Ignore heartbeats
        :ok

      other ->
        Logger.debug("Unknown update type: #{other}")
    end
  end

  defp decode_any_value(nil), do: nil

  defp decode_any_value(any) do
    # Simple JSON decoder - variable serialization system removed
    case Jason.decode(any.value) do
      {:ok, value} -> value
      {:error, _} -> any.value
    end
  end
end
