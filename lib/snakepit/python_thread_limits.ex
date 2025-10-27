defmodule Snakepit.PythonThreadLimits do
  @moduledoc """
  Normalizes Python threading configuration with safe defaults.

  Resolves partial overrides pulled from application environment and
  produces a complete map ready for runtime consumption.
  """

  @typedoc "Thread limit configuration keyed by known library identifiers."
  @type t :: %{
          optional(:openblas) => pos_integer(),
          optional(:omp) => pos_integer(),
          optional(:mkl) => pos_integer(),
          optional(:numexpr) => pos_integer(),
          optional(:grpc_poll_threads) => pos_integer()
        }

  @defaults %{
    openblas: 1,
    omp: 1,
    mkl: 1,
    numexpr: 1,
    grpc_poll_threads: 1
  }

  @doc "Default thread limit configuration."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  Merge a user-supplied configuration with defaults.

  Accepts `nil`, maps with atom keys, or keyword lists.
  Unknown keys are ignored; non-integer values are coerced with `String.to_integer/1`
  when possible.
  """
  @spec resolve(nil | map() | keyword()) :: t()
  def resolve(nil), do: defaults()

  def resolve(config) when is_list(config) do
    config
    |> Enum.into(%{})
    |> resolve()
  end

  def resolve(config) when is_map(config) do
    config
    |> Enum.reduce(defaults(), fn {key, value}, acc ->
      key = normalize_key(key)

      case key do
        nil ->
          acc

        normalized_key ->
          Map.put(acc, normalized_key, normalize_value(value))
      end
    end)
  end

  def resolve(_unknown), do: defaults()

  @known_keys %{
    "openblas" => :openblas,
    "omp" => :omp,
    "mkl" => :mkl,
    "numexpr" => :numexpr,
    "grpc_poll_threads" => :grpc_poll_threads
  }

  defp normalize_key(key) when is_atom(key) do
    if Map.has_key?(defaults(), key), do: key, else: nil
  end

  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, key)
  defp normalize_key(_), do: nil

  defp normalize_value(value) when is_integer(value) and value > 0, do: value

  defp normalize_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_value(_), do: 1
end
