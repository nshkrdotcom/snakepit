defmodule Snakepit.Error.PythonTranslation do
  @moduledoc false

  alias Snakepit.Error

  @mapping %{
    "ValueError" => Error.ValueError,
    "KeyError" => Error.KeyError,
    "IndexError" => Error.IndexError,
    "TypeError" => Error.TypeError,
    "AttributeError" => Error.AttributeError,
    "ImportError" => Error.ImportError,
    "RuntimeError" => Error.RuntimeError,
    "NotImplementedError" => Error.NotImplementedError,
    "FileNotFoundError" => Error.FileNotFoundError,
    "PermissionError" => Error.PermissionError,
    "ZeroDivisionError" => Error.ZeroDivisionError
  }

  def from_error_message(error_message) when is_binary(error_message) do
    with {:ok, payload} <- Jason.decode(error_message),
         true <- is_map(payload),
         {:ok, exception} <- from_payload(payload) do
      {:ok, exception}
    else
      _ -> :error
    end
  end

  def from_error_message(_), do: :error

  def from_payload(payload) when is_map(payload) do
    type = fetch(payload, ["type", :type])
    message = fetch(payload, ["message", :message])

    if is_binary(type) and is_binary(message) do
      context = fetch(payload, ["context", :context]) || %{}
      stacktrace = fetch(payload, ["stacktrace", :stacktrace]) || []
      python_traceback = fetch(payload, ["traceback", :traceback]) || join_stacktrace(stacktrace)

      module = Map.get(@mapping, type, Error.PythonException)
      mapped? = Map.has_key?(@mapping, type)

      exception =
        struct(module, %{
          message: message,
          context: context,
          stacktrace: stacktrace,
          python_type: type,
          python_traceback: python_traceback
        })

      emit_exception_event(mapped?, type, context)
      {:ok, exception}
    else
      :error
    end
  end

  def from_payload(_), do: :error

  defp fetch(payload, keys) do
    Enum.find_value(keys, fn key -> Map.get(payload, key) end)
  end

  defp join_stacktrace(stacktrace) when is_list(stacktrace) do
    Enum.map_join(stacktrace, "", &to_string/1)
  end

  defp join_stacktrace(_), do: nil

  defp emit_exception_event(mapped?, python_type, context) do
    event =
      if mapped? do
        [:snakepit, :python, :exception, :mapped]
      else
        [:snakepit, :python, :exception, :unmapped]
      end

    metadata = %{
      python_type: python_type,
      library: fetch(context, ["library", :library]),
      function: fetch(context, ["function", :function])
    }

    :telemetry.execute(event, %{}, metadata)
  end
end
