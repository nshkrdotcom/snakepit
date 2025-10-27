defmodule Snakepit.Logger.Redaction do
  @moduledoc false

  @max_map_keys 5
  @max_key_length 32
  @sample_limit 5

  def describe(%struct_module{} = _struct) do
    module =
      struct_module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")

    "struct(#{module})"
  end

  def describe(map) when is_map(map) do
    keys =
      map
      |> Map.delete(:__struct__)
      |> Map.keys()
      |> Enum.map(&format_key/1)
      |> Enum.take(@max_map_keys)

    "map(keys: #{inspect(keys)}, count: #{map_size(map)})"
  end

  def describe(binary) when is_binary(binary) do
    "binary(len: #{byte_size(binary)})"
  end

  def describe(list) when is_list(list) do
    length = length(list)

    sample_types =
      list
      |> Enum.take(@sample_limit)
      |> Enum.map(&type_label/1)

    "list(len: #{length}, sample_types: #{Enum.join(sample_types, ",")})"
  end

  def describe(tuple) when is_tuple(tuple) do
    "tuple(size: #{tuple_size(tuple)})"
  end

  def describe(number) when is_number(number), do: inspect(number)
  def describe(atom) when is_atom(atom), do: Atom.to_string(atom)
  def describe(pid) when is_pid(pid), do: inspect(pid)
  def describe(ref) when is_reference(ref), do: inspect(ref)
  def describe(port) when is_port(port), do: inspect(port)
  def describe(fun) when is_function(fun), do: "function/arity=#{:erlang.fun_info(fun)[:arity]}"
  def describe(nil), do: "nil"

  def describe(term) do
    type_label(term)
  end

  defp format_key(key) when is_atom(key) do
    key |> Atom.to_string() |> truncate()
  end

  defp format_key(key) when is_binary(key) do
    key |> truncate()
  end

  defp format_key(key) do
    key |> inspect() |> truncate()
  end

  defp truncate(value) do
    if String.length(value) > @max_key_length do
      String.slice(value, 0, @max_key_length) <> "..."
    else
      value
    end
  end

  defp type_label(%struct_module{}) do
    module =
      struct_module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")

    "struct(#{module})"
  end

  defp type_label(term) when is_map(term), do: "map"
  defp type_label(term) when is_binary(term), do: "binary"
  defp type_label(term) when is_list(term), do: "list"
  defp type_label(term) when is_tuple(term), do: "tuple"
  defp type_label(term) when is_integer(term), do: "integer"
  defp type_label(term) when is_float(term), do: "float"
  defp type_label(term) when is_atom(term), do: Atom.to_string(term)
  defp type_label(term) when is_pid(term), do: "pid"
  defp type_label(term) when is_reference(term), do: "reference"
  defp type_label(term) when is_function(term), do: "function"
  defp type_label(nil), do: "nil"
  defp type_label(_term), do: "unknown"
end
