defmodule Snakepit.Error.Parser do
  @moduledoc """
  Parses Python exception data into structured Elixir errors.

  Automatically detects error patterns (OOM, shape mismatch, device errors)
  and creates appropriate structured exceptions.
  """

  alias Snakepit.Error.{Device, Shape}

  @doc """
  Parses error data into a structured error.

  Accepts a map with "type", "message", and optionally "traceback".

  ## Examples

      {:ok, error} = Parser.parse(%{
        "type" => "ValueError",
        "message" => "Invalid input"
      })
  """
  @spec parse(map() | term()) :: {:ok, Exception.t()} | {:error, :invalid_input}
  def parse(nil), do: {:error, :invalid_input}
  def parse(data) when not is_map(data), do: {:error, :invalid_input}

  def parse(%{"type" => type, "message" => message} = data) do
    traceback = Map.get(data, "traceback")

    error =
      cond do
        shape_mismatch?(message) ->
          parse_shape_mismatch(message)

        oom_error?(message) ->
          parse_oom_error(message)

        device_mismatch?(message) ->
          parse_device_mismatch(message)

        true ->
          create_typed_error(type, message, traceback, data)
      end

    {:ok, error}
  end

  def parse(%{}), do: {:error, :invalid_input}

  @doc """
  Parses a gRPC error response into a structured error.
  """
  @spec from_grpc_error(map()) :: {:ok, Exception.t()} | {:error, :invalid_input}
  def from_grpc_error(%{status: _status, message: message}) when is_binary(message) do
    # Try to parse as JSON first
    case Jason.decode(message) do
      {:ok, data} when is_map(data) ->
        parse(data)

      _ ->
        # Parse from message string
        parse_from_message(message)
    end
  end

  def from_grpc_error(_), do: {:error, :invalid_input}

  @doc """
  Extracts a shape from a string representation.

  ## Examples

      iex> Parser.extract_shape("[3, 224, 224]")
      [3, 224, 224]

      iex> Parser.extract_shape("(10, 20)")
      [10, 20]
  """
  @spec extract_shape(String.t()) :: [integer()] | nil
  def extract_shape(str) do
    # Try bracket notation [a, b, c]
    case Regex.run(~r/\[([0-9,\s]+)\]/, str) do
      [_, dims] ->
        parse_dims(dims)

      nil ->
        # Try tuple notation (a, b, c)
        case Regex.run(~r/\(([0-9,\s]+)\)/, str) do
          [_, dims] -> parse_dims(dims)
          nil -> nil
        end
    end
  end

  defp parse_dims(dims) do
    dims
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_int/1)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  # Pattern detection helpers

  defp shape_mismatch?(message) do
    String.contains?(String.downcase(message), "shape") and
      (String.contains?(message, "mismatch") or
         String.contains?(message, "expected") or
         String.contains?(message, "got"))
  end

  defp oom_error?(message) do
    lower = String.downcase(message)

    String.contains?(lower, "out of memory") or
      String.contains?(lower, "oom") or
      (String.contains?(lower, "cuda") and String.contains?(lower, "allocate"))
  end

  defp device_mismatch?(message) do
    lower = String.downcase(message)

    String.contains?(lower, "device") and
      (String.contains?(lower, "mismatch") or
         String.contains?(lower, "expected") or
         String.contains?(lower, "same device"))
  end

  # Pattern parsing helpers

  defp parse_shape_mismatch(message) do
    # Try to extract expected and got shapes
    expected = extract_first_shape(message, "expected")
    got = extract_first_shape(message, "got")

    if expected && got do
      Shape.shape_mismatch(expected, got, extract_operation(message))
    else
      Shape.shape_mismatch([], [], extract_operation(message))
    end
  end

  defp extract_first_shape(message, prefix) do
    pattern = ~r/#{prefix}\s*:?\s*(\[[0-9,\s]+\]|\([0-9,\s]+\))/i

    case Regex.run(pattern, message) do
      [_, shape_str] -> extract_shape(shape_str)
      nil -> nil
    end
  end

  defp parse_oom_error(message) do
    # Extract device
    device = extract_device(message) || {:cuda, 0}

    # Try to extract memory values
    {requested, available} = extract_memory_values(message)

    Device.out_of_memory(device, requested, available)
  end

  defp extract_memory_values(message) do
    # Try to find "allocate X" pattern
    requested =
      case Regex.run(~r/allocate\s+([\d.]+)\s*(GB|MB|GiB|MiB)/i, message) do
        [_, num, unit] -> parse_memory(num, unit)
        nil -> 0
      end

    # Try to find "available X" or "free X" pattern
    available =
      case Regex.run(~r/(available|free)\s+([\d.]+)\s*(GB|MB|GiB|MiB)/i, message) do
        [_, _, num, unit] -> parse_memory(num, unit)
        nil -> 0
      end

    {requested, available}
  end

  defp parse_memory(num_str, unit) do
    {num, _} = Float.parse(num_str)

    case String.upcase(unit) do
      u when u in ["GB", "GIB"] -> trunc(num * 1_073_741_824)
      u when u in ["MB", "MIB"] -> trunc(num * 1_048_576)
      _ -> trunc(num)
    end
  end

  defp parse_device_mismatch(message) do
    # Try to extract device names
    expected = extract_device(message)
    got = extract_second_device(message)

    Device.device_mismatch(expected || :cpu, got || :cpu, extract_operation(message))
  end

  defp extract_device(message) do
    cond do
      String.contains?(message, "cuda:") ->
        case Regex.run(~r/cuda:(\d+)/i, message) do
          [_, id] -> {:cuda, String.to_integer(id)}
          nil -> {:cuda, 0}
        end

      String.contains?(String.downcase(message), "cuda") ->
        {:cuda, 0}

      String.contains?(String.downcase(message), "mps") ->
        :mps

      String.contains?(String.downcase(message), "cpu") ->
        :cpu

      true ->
        nil
    end
  end

  defp extract_second_device(message) do
    # Look for second device after "and"
    case Regex.run(~r/and\s+(cuda:\d+|cpu|mps)/i, message) do
      [_, device_str] -> parse_device_string(device_str)
      nil -> nil
    end
  end

  defp parse_device_string(str) do
    lower = String.downcase(str)

    cond do
      String.starts_with?(lower, "cuda:") ->
        [_, id] = Regex.run(~r/cuda:(\d+)/i, str)
        {:cuda, String.to_integer(id)}

      lower == "cuda" ->
        {:cuda, 0}

      lower == "cpu" ->
        :cpu

      lower == "mps" ->
        :mps

      true ->
        nil
    end
  end

  defp extract_operation(message) do
    # Try to find operation name in common patterns
    case Regex.run(~r/(?:in|during|for)\s+(\w+)/i, message) do
      [_, op] -> op
      nil -> "unknown"
    end
  end

  defp parse_from_message(message) do
    # Try to extract type from "TypeName: message" pattern
    case Regex.run(~r/^(\w+Error):\s*(.+)$/i, message) do
      [_, type, msg] ->
        parse(%{"type" => type, "message" => msg})

      nil ->
        {:ok, %Snakepit.Error.PythonException{python_type: "Unknown", message: message}}
    end
  end

  defp create_typed_error(type, message, traceback, _data) do
    case type do
      "ValueError" ->
        %Snakepit.Error.ValueError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "TypeError" ->
        %Snakepit.Error.TypeError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "KeyError" ->
        %Snakepit.Error.KeyError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "IndexError" ->
        %Snakepit.Error.IndexError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "AttributeError" ->
        %Snakepit.Error.AttributeError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "RuntimeError" ->
        %Snakepit.Error.RuntimeError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      "ImportError" ->
        %Snakepit.Error.ImportError{
          python_type: type,
          message: message,
          python_traceback: traceback
        }

      _ ->
        %Snakepit.Error.PythonException{
          python_type: type,
          message: message,
          python_traceback: traceback
        }
    end
  end
end
