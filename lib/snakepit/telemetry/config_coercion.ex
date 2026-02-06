defmodule Snakepit.Telemetry.ConfigCoercion do
  @moduledoc false

  @spec truthy?(term()) :: boolean()
  def truthy?(value) when is_boolean(value), do: value

  def truthy?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))
    normalized in ["true", "1", "yes", "on"]
  end

  def truthy?(value) when is_integer(value), do: value != 0
  def truthy?(_), do: false

  @spec to_map(term(), map()) :: term()
  def to_map(value, template \\ %{})

  def to_map(value, template) when is_map(value) and is_map(template) do
    value
    |> Enum.map(fn {key, val} ->
      normalized_key = normalize_key(key, template)
      nested_template = Map.get(template, normalized_key, %{})
      {normalized_key, to_map(val, nested_template)}
    end)
    |> Enum.into(%{})
  end

  def to_map(value, _template) when is_map(value), do: value

  def to_map(value, template) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, val} ->
        normalized_key = normalize_key(key, template)
        nested_template = Map.get(template, normalized_key, %{})
        {normalized_key, to_map(val, nested_template)}
      end)
      |> Enum.into(%{})
    else
      Enum.map(value, &to_map(&1, %{}))
    end
  end

  def to_map(other, _template), do: other

  defp normalize_key(key, _template) when is_atom(key), do: key

  defp normalize_key(key, template) do
    case key_string(key) do
      nil ->
        key

      key_str ->
        Enum.find(Map.keys(template), key, fn
          atom_key when is_atom(atom_key) -> Atom.to_string(atom_key) == key_str
          _ -> false
        end)
    end
  end

  defp key_string(key) when is_binary(key), do: key

  defp key_string(key) do
    to_string(key)
  rescue
    Protocol.UndefinedError -> nil
  end
end
