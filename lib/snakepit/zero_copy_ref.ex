defmodule Snakepit.ZeroCopyRef do
  @moduledoc """
  Opaque handle for zero-copy payloads.

  The handle metadata travels through the runtime so adapters can resolve
  DLPack or Arrow buffers without copying.
  """

  @type kind :: :dlpack | :arrow
  @type device :: :cpu | :cuda | :mps

  @enforce_keys [:kind, :ref]
  defstruct [
    :kind,
    :device,
    :dtype,
    :shape,
    :owner,
    :ref,
    :copy,
    :bytes,
    :metadata
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          device: device() | nil,
          dtype: atom() | String.t() | nil,
          shape: tuple() | list() | nil,
          owner: :elixir | :python | nil,
          ref: reference(),
          copy: boolean() | nil,
          bytes: non_neg_integer() | nil,
          metadata: map() | nil
        }

  @doc false
  def to_map(%__MODULE__{} = ref) do
    %{
      "__snakepit_zero_copy__" => true,
      "kind" => Atom.to_string(ref.kind),
      "device" => maybe_string(ref.device),
      "dtype" => maybe_string(ref.dtype),
      "shape" => ref.shape,
      "owner" => maybe_string(ref.owner),
      "ref" => encode_ref(ref.ref),
      "copy" => ref.copy,
      "bytes" => ref.bytes,
      "metadata" => ref.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc false
  def maybe_from_map(%{"__snakepit_zero_copy__" => true} = map), do: from_map(map)
  def maybe_from_map(%{__snakepit_zero_copy__: true} = map), do: from_map(map)
  def maybe_from_map(other), do: other

  @doc false
  def from_map(map) when is_map(map) do
    ref =
      map
      |> fetch_value([:ref, "ref"])
      |> decode_ref()

    %__MODULE__{
      kind: map |> fetch_value([:kind, "kind"]) |> to_kind(),
      device: map |> fetch_value([:device, "device"]) |> to_device(),
      dtype: fetch_value(map, [:dtype, "dtype"]),
      shape: fetch_value(map, [:shape, "shape"]),
      owner: map |> fetch_value([:owner, "owner"]) |> to_owner(),
      ref: ref,
      copy: fetch_value(map, [:copy, "copy"]),
      bytes: fetch_value(map, [:bytes, "bytes"]),
      metadata: fetch_value(map, [:metadata, "metadata"])
    }
  end

  defp fetch_value(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp encode_ref(ref) when is_reference(ref) do
    ref
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp decode_ref(ref) when is_reference(ref), do: ref

  defp decode_ref(ref) when is_binary(ref) do
    ref
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defp decode_ref(_), do: make_ref()

  defp to_kind(kind) when is_atom(kind), do: kind

  defp to_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "dlpack" -> :dlpack
      "arrow" -> :arrow
      _ -> :dlpack
    end
  end

  defp to_kind(_), do: :dlpack

  defp to_device(device) when is_atom(device), do: device

  defp to_device(device) when is_binary(device) do
    case String.downcase(device) do
      "cpu" -> :cpu
      "cuda" -> :cuda
      "mps" -> :mps
      _ -> nil
    end
  end

  defp to_device(_), do: nil

  defp to_owner(owner) when is_atom(owner), do: owner

  defp to_owner(owner) when is_binary(owner) do
    case String.downcase(owner) do
      "elixir" -> :elixir
      "python" -> :python
      _ -> nil
    end
  end

  defp to_owner(_), do: nil

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_string(value), do: to_string(value)
end

defimpl Jason.Encoder, for: Snakepit.ZeroCopyRef do
  def encode(ref, opts) do
    ref
    |> Snakepit.ZeroCopyRef.to_map()
    |> Jason.Encode.map(opts)
  end
end
