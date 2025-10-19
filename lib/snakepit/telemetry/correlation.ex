defmodule Snakepit.Telemetry.Correlation do
  @moduledoc """
  Utilities for generating and propagating correlation identifiers.
  """

  @prefix "sp"

  @doc """
  Generates a new correlation identifier.
  """
  @spec new_id() :: String.t()
  def new_id do
    random = :crypto.strong_rand_bytes(12)
    encoded = Base.encode16(random, case: :lower)
    "#{@prefix}-#{encoded}"
  end

  @doc """
  Ensures a non-empty correlation identifier is present.
  """
  @spec ensure(String.t() | nil) :: String.t()
  def ensure(nil), do: new_id()
  def ensure(""), do: new_id()
  def ensure(id) when is_binary(id), do: id
  def ensure(_other), do: new_id()
end
