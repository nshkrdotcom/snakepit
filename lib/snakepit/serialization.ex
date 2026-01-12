defmodule Snakepit.Serialization do
  @moduledoc """
  Utilities for working with Snakepit's serialization layer.

  When Python returns data to Elixir, non-JSON-serializable objects (like
  `datetime.datetime`, custom classes, or library-specific objects) are
  handled gracefully by Snakepit's serialization layer:

  1. Objects with conversion methods (`model_dump`, `to_dict`, `_asdict`,
     `tolist`, `isoformat`) are automatically converted.

  2. Objects that cannot be converted are replaced with an "unserializable marker"
     containing type information.

  This module provides utilities for detecting and inspecting these markers.

  ## Marker Format

  Unserializable markers are maps with the following structure:

      %{
        "__ffi_unserializable__" => true,
        "__type__" => "module.ClassName"   # Full Python type path
      }

  By default, the marker only contains type information (safe for production).
  The `__repr__` field is only included when explicitly enabled via environment
  variables.

  ## Environment Variables

  The following environment variables control marker detail level. These are
  set on the Python worker processes, typically via pool configuration:

  - `SNAKEPIT_UNSERIALIZABLE_DETAIL` - Controls what information is included:
    - `none` (default) - Only type, no repr (safe for production)
    - `type` - Placeholder string with type name
    - `repr_truncated` - Include truncated repr (may leak secrets)
    - `repr_redacted_truncated` - Truncated repr with common secrets redacted

  - `SNAKEPIT_UNSERIALIZABLE_REPR_MAXLEN` - Maximum repr length (default: 500, max: 2000)

  ## Operational Guidance

  - **Production**: Use default (`none`) or omit the env vars entirely
  - **Development/Debugging**: Use `repr_redacted_truncated` with small maxlen
  - **Never in production**: `repr_truncated` without redaction

  ## Example Usage

      # Check if a value is an unserializable marker
      if Snakepit.Serialization.unserializable?(value) do
        {:ok, info} = Snakepit.Serialization.unserializable_info(value)
        IO.puts("Cannot serialize: \#{info.type}")
      end

  ## Security Note

  When repr is enabled, the `__repr__` field may contain sensitive information
  (API keys, auth tokens, etc.) that was present in the Python object's string
  representation. The `repr_redacted_truncated` mode applies best-effort
  redaction of common secret patterns but is NOT a security boundary.
  """

  @marker_key "__ffi_unserializable__"

  @doc """
  Checks if a value is an unserializable marker.

  Returns `true` if the value is a map with `"__ffi_unserializable__" => true`,
  indicating it represents a Python object that could not be serialized to JSON.

  ## Examples

      iex> Snakepit.Serialization.unserializable?(%{"__ffi_unserializable__" => true})
      true

      iex> Snakepit.Serialization.unserializable?(%{"key" => "value"})
      false

      iex> Snakepit.Serialization.unserializable?(nil)
      false
  """
  @spec unserializable?(term()) :: boolean()
  def unserializable?(%{@marker_key => true}), do: true
  def unserializable?(_), do: false

  @doc """
  Extracts information from an unserializable marker.

  Returns `{:ok, info}` if the value is a valid unserializable marker,
  where `info` is a map with `:type` and `:repr` keys. Returns `:error`
  for non-marker values.

  ## Examples

      iex> marker = %{
      ...>   "__ffi_unserializable__" => true,
      ...>   "__type__" => "datetime.datetime",
      ...>   "__repr__" => "datetime.datetime(2024, 1, 11, 10, 30)"
      ...> }
      iex> {:ok, info} = Snakepit.Serialization.unserializable_info(marker)
      iex> info.type
      "datetime.datetime"

      iex> Snakepit.Serialization.unserializable_info(%{"key" => "value"})
      :error

  ## Return Value

  On success, returns `{:ok, %{type: String.t() | nil, repr: String.t() | nil}}`.
  The `:type` and `:repr` fields may be `nil` if not present in the marker.
  """
  @spec unserializable_info(term()) ::
          {:ok, %{type: String.t() | nil, repr: String.t() | nil}} | :error
  def unserializable_info(%{@marker_key => true} = marker) do
    {:ok,
     %{
       type: Map.get(marker, "__type__"),
       repr: Map.get(marker, "__repr__")
     }}
  end

  def unserializable_info(_), do: :error
end
