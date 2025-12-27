defmodule Snakepit.ZeroCopy do
  @moduledoc """
  Zero-copy interop helpers for DLPack and Arrow.

  Handles create/import lifecycle for zero-copy handles, with copy-based
  fallbacks when unavailable.
  """

  alias Snakepit.Logger, as: SLog
  alias Snakepit.ZeroCopyRef

  @table :snakepit_zero_copy_handles
  @log_category :bridge

  @default_config %{
    enabled: false,
    dlpack: true,
    arrow: true,
    allow_fallback: true,
    max_bytes: 64 * 1024 * 1024,
    strict: false
  }

  @type export_opts ::
          [
            device: ZeroCopyRef.device(),
            dtype: atom() | String.t(),
            shape: tuple() | list(),
            owner: :elixir | :python
          ]

  def to_dlpack(term, opts \\ []), do: export(:dlpack, term, opts)
  def to_arrow(term, opts \\ []), do: export(:arrow, term, opts)

  def from_dlpack(ref, opts \\ []), do: import(:dlpack, ref, opts)
  def from_arrow(ref, opts \\ []), do: import(:arrow, ref, opts)

  def close(ref) do
    ref = normalize_ref(ref)
    ensure_table()
    :ets.delete(@table, ref.ref)
    :ok
  end

  defp export(kind, term, opts) when kind in [:dlpack, :arrow] do
    start = System.monotonic_time(:microsecond)
    config = config()
    meta = build_metadata(kind, term, opts)

    cond do
      zero_copy_enabled?(config, kind) ->
        ref = store_handle(kind, term, meta, copy?: false)
        emit(:export, start, ref)
        {:ok, ref}

      config.allow_fallback ->
        SLog.warning(
          @log_category,
          "Zero-copy #{kind} unavailable; falling back to copy (reason: :zero_copy_unavailable)"
        )

        ref = store_handle(kind, copy_term(term), meta, copy?: true)
        emit(:fallback, start, ref)
        {:ok, ref}

      config.strict ->
        {:error, :zero_copy_unavailable}

      true ->
        {:error, :zero_copy_unavailable}
    end
  end

  defp import(kind, ref, _opts) when kind in [:dlpack, :arrow] do
    start = System.monotonic_time(:microsecond)
    ref = normalize_ref(ref)
    ensure_table()

    case :ets.lookup(@table, ref.ref) do
      [{_ref, stored_kind, value, metadata}] when stored_kind == kind ->
        emit(:import, start, Map.merge(ref, metadata))
        {:ok, value}

      [{_ref, stored_kind, _value, _metadata}] ->
        {:error, {:invalid_zero_copy_kind, stored_kind}}

      _ ->
        {:error, :zero_copy_handle_not_found}
    end
  end

  defp store_handle(kind, term, metadata, opts) do
    ensure_table()
    ref = make_ref()
    entry = {ref, kind, term, metadata}
    true = :ets.insert(@table, entry)

    %ZeroCopyRef{
      kind: kind,
      device: metadata.device,
      dtype: metadata.dtype,
      shape: metadata.shape,
      owner: metadata.owner,
      ref: ref,
      copy: Keyword.get(opts, :copy?, false),
      bytes: metadata.bytes,
      metadata: metadata.extra
    }
  end

  defp build_metadata(kind, term, opts) do
    %{
      kind: kind,
      device: Keyword.get(opts, :device, :cpu),
      dtype: Keyword.get(opts, :dtype),
      shape: Keyword.get(opts, :shape),
      owner: Keyword.get(opts, :owner, :elixir),
      bytes: term_bytes(term),
      extra: Keyword.get(opts, :metadata, %{})
    }
  end

  defp emit(event, start_us, %ZeroCopyRef{} = ref) do
    duration_us = System.monotonic_time(:microsecond) - start_us

    measurements =
      %{duration_ms: duration_us / 1000}
      |> maybe_put(:bytes, ref.bytes)

    metadata = %{
      kind: ref.kind,
      device: ref.device,
      dtype: ref.dtype,
      shape: ref.shape
    }

    :telemetry.execute([:snakepit, :zero_copy, event], measurements, metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp copy_term(term) do
    term
    |> :erlang.term_to_binary()
    |> :erlang.binary_to_term()
  end

  defp term_bytes(term) when is_binary(term), do: byte_size(term)

  defp term_bytes(term) do
    if function_exported?(:erlang, :external_size, 1) do
      :erlang.external_size(term)
    else
      nil
    end
  end

  defp zero_copy_enabled?(config, :dlpack),
    do: config.enabled && config.dlpack

  defp zero_copy_enabled?(config, :arrow),
    do: config.enabled && config.arrow

  defp config do
    config =
      :snakepit
      |> Application.get_env(:zero_copy, [])
      |> Map.new()

    Map.merge(@default_config, config)
  end

  defp normalize_ref(%ZeroCopyRef{} = ref), do: ref
  defp normalize_ref(map) when is_map(map), do: ZeroCopyRef.from_map(map)
  defp normalize_ref(_), do: %ZeroCopyRef{kind: :dlpack, ref: make_ref()}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])

      _ ->
        @table
    end
  end
end
