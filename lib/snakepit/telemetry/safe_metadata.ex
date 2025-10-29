defmodule Snakepit.Telemetry.SafeMetadata do
  @moduledoc """
  Safe metadata handling for telemetry events.

  This module ensures that metadata from Python workers doesn't create
  new atoms at runtime, which could exhaust the BEAM atom table.

  Only keys from the allowlist are converted to atoms; everything else
  remains as strings.
  """

  # Metadata keys that are safe to convert to atoms
  @allowed_atom_keys [
    :node,
    :pool_name,
    :worker_id,
    :session_id,
    :command,
    :correlation_id,
    :worker_pid,
    :python_port,
    :python_pid,
    :mode,
    :reason,
    :planned,
    :previous_pid,
    :new_pid,
    :retry_count,
    :timeout_ms,
    :result,
    :error_type,
    :error_category,
    :error_message,
    :traceback,
    :rpc_method,
    :grpc_status,
    :stream_id,
    :direction,
    :is_final,
    :tool,
    :model,
    :operation,
    :timestamp_ns,
    :worker_module,
    :adapter_module,
    :size,
    :failure_reason
  ]

  @doc """
  Enriches metadata from Python with Elixir context.

  Only allowed keys are converted to atoms; unknown keys remain as strings.

  ## Examples

      iex> Snakepit.Telemetry.SafeMetadata.enrich(
      ...>   %{"tool" => "predict"},
      ...>   [node: :nonode@nohost, worker_id: "worker_1"]
      ...> )
      {:ok, %{tool: "predict", node: :nonode@nohost, worker_id: "worker_1"}}
  """
  def enrich(python_metadata, elixir_context)
      when is_map(python_metadata) and is_list(elixir_context) do
    with {:ok, safe_python} <- sanitize(python_metadata),
         {:ok, safe_elixir} <- sanitize(Map.new(elixir_context)) do
      {:ok, Map.merge(safe_python, safe_elixir)}
    end
  end

  @doc """
  Sanitizes a metadata map, converting only allowed keys to atoms.

  ## Examples

      iex> Snakepit.Telemetry.SafeMetadata.sanitize(%{"node" => "test@host", "unknown" => "value"})
      {:ok, %{node: "test@host", "unknown" => "value"}}
  """
  def sanitize(metadata) when is_map(metadata) do
    safe_metadata =
      Enum.reduce(metadata, %{}, fn {key, value}, acc ->
        safe_key = safe_key(key)
        Map.put(acc, safe_key, value)
      end)

    {:ok, safe_metadata}
  end

  @doc """
  Validates and converts measurements map.

  All measurement keys must be from the allowlist (enforced by Naming module).

  ## Examples

      iex> Snakepit.Telemetry.SafeMetadata.measurements(%{"duration" => 1000})
      {:ok, %{duration: 1000}}
  """
  def measurements(measurements) when is_map(measurements) do
    result =
      Enum.reduce_while(measurements, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case Snakepit.Telemetry.Naming.measurement_key(key) do
          {:ok, atom_key} ->
            {:cont, {:ok, Map.put(acc, atom_key, value)}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_measurement_key, key, reason}}}
        end
      end)

    result
  end

  # Private Helpers

  defp safe_key(key) when is_atom(key) do
    if key in @allowed_atom_keys do
      key
    else
      Atom.to_string(key)
    end
  end

  defp safe_key(key) when is_binary(key) do
    try do
      atom_key = String.to_existing_atom(key)

      if atom_key in @allowed_atom_keys do
        atom_key
      else
        key
      end
    rescue
      ArgumentError -> key
    end
  end

  defp safe_key(key), do: to_string(key)

  @doc """
  Merges two metadata maps safely.

  ## Examples

      iex> Snakepit.Telemetry.SafeMetadata.merge(%{"tool" => "predict"}, %{node: :nonode@nohost})
      {:ok, %{"tool" => "predict", node: :nonode@nohost}}
  """
  def merge(metadata1, metadata2) when is_map(metadata1) and is_map(metadata2) do
    with {:ok, safe1} <- sanitize(metadata1),
         {:ok, safe2} <- sanitize(metadata2) do
      {:ok, Map.merge(safe1, safe2)}
    end
  end

  @doc """
  Returns the list of allowed atom keys.
  """
  def allowed_atom_keys, do: @allowed_atom_keys
end
