defmodule Snakepit.Utils do
  @moduledoc """
  Utility functions for Snakepit.

  This module contains common helper functions used across the Snakepit codebase
  to avoid code duplication and provide consistent behavior.
  """

  @doc """
  Recursively converts atom keys to string keys in maps and lists.

  This is useful when preparing data for JSON serialization where all keys
  need to be strings.

  ## Examples

      iex> Snakepit.Utils.stringify_keys(%{foo: "bar", baz: %{nested: "value"}})
      %{"foo" => "bar", "baz" => %{"nested" => "value"}}
      
      iex> Snakepit.Utils.stringify_keys([%{key: "value"}, %{another: "test"}])
      [%{"key" => "value"}, %{"another" => "test"}]
      
      iex> Snakepit.Utils.stringify_keys("already_string")
      "already_string"
  """
  @spec stringify_keys(any()) :: any()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  def stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  def stringify_keys(value), do: value

  @doc """
  Determines which worker module to use based on the adapter's capabilities.

  Returns `Snakepit.GRPCWorker` if the adapter supports gRPC,
  otherwise returns `Snakepit.Pool.Worker`.

  ## Examples

      iex> Snakepit.Utils.determine_worker_module(Snakepit.Adapters.GRPCBridge)
      Snakepit.GRPCWorker
      
      iex> Snakepit.Utils.determine_worker_module(Snakepit.Adapters.Python)
      Snakepit.Pool.Worker
  """
  @spec determine_worker_module(module()) :: module()
  def determine_worker_module(adapter) do
    # Ensure the adapter module is loaded
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :uses_grpc?, 0) and adapter.uses_grpc?() do
      Snakepit.GRPCWorker
    else
      Snakepit.Pool.Worker
    end
  end
end
